import Foundation
import Darwin

/// A child started with `posix_spawn` as the leader of its own process group, so the whole tree it spawns
/// (yt-dlp -> ffmpeg) can be signalled at once with `kill(-pgid, …)`. Foundation's `Process` can't do that.
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    /// Read ends of the child's stdout/stderr. Hand them to a `PipeReader`, which closes them.
    let stdoutFD: Int32
    let stderrFD: Int32

    private let exitGroup = DispatchGroup()
    private let lock = NSLock()
    private var _status: Int32?
    private var exitSource: DispatchSourceProcess?

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        exitGroup.enter()
        // A process source reports the exit; no thread sits in waitpid.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [self] in reap(blocking: true) }
        lock.withLock { exitSource = source }
        source.resume()
        // The child may already have exited before the source was armed.
        reap(blocking: false)
    }

    /// Collects the exit status once; later calls are no-ops.
    private func reap(blocking: Bool) {
        let source: DispatchSourceProcess? = lock.withLock {
            guard _status == nil else { return nil }
            var raw: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(pid, &raw, blocking ? 0 : WNOHANG) } while r < 0 && errno == EINTR
            guard r == pid else { return nil }
            let signal = raw & 0x7f
            _status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            defer { exitSource = nil }
            return exitSource
        }
        guard lock.withLock({ _status }) != nil, let source else { return }
        source.cancel()
        exitGroup.leave()
    }

    /// Starts `executable` with stdin from /dev/null and stdout/stderr on new pipes, in a new process group.
    static func spawn(executable: URL, arguments: [String], environment: [String: String]) throws -> ChildProcess {
        let path = executable.path(percentEncoded: false)
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw MediaError.toolMissing(executable.lastPathComponent) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw MediaError.toolMissing(executable.lastPathComponent)
        }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        // New group led by the child; every other descriptor is closed; default signal dispositions and an empty mask,
        // so a SIGINT that the host ignores can't leak into the tool.
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw MediaError.toolMissing(executable.lastPathComponent)
        }
        let child = ChildProcess(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0])
        // Tracked until its owner is done with the group, so quitting can kill it (it's not in the app's group).
        MediaCleanup.shared.register(child)
        return child
    }

    var isRunning: Bool { lock.withLock { _status == nil } }

    /// Signals every process in the child's group (the child and anything it spawned that stayed in the group).
    func signalGroup(_ signal: Int32) { kill(-pid, signal) }

    /// True while some process still belongs to the child's group.
    var groupExists: Bool { kill(-pid, 0) == 0 }

    /// The exit code, or 128 + signal number when the child was killed.
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            exitGroup.notify(queue: .global()) { [self] in
                cont.resume(returning: lock.withLock { _status ?? -1 })
            }
        }
    }

    /// SIGTERM to the group now, SIGKILL `grace` seconds later if anything in the group is still alive.
    func terminateGroupThenKill(grace: TimeInterval = 2) {
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if groupExists { signalGroup(SIGKILL) }
        }
    }
}

/// Reads a pipe with a dispatch read source (no thread is parked in read), then closes the descriptor.
final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let group = DispatchGroup()
    private let keepLimit: Int
    private let source: DispatchSourceRead

    /// - keep: bytes of output to retain for `collected()` (0 keeps nothing).
    init(fd: Int32, keep: Int = 0, onData: (@Sendable (Data) -> Void)? = nil, onEnd: (@Sendable () -> Void)? = nil) {
        keepLimit = keep
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "osprey.pipe-reader"))
        group.enter()
        source.setEventHandler { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    let data = Data(chunk[0..<n])
                    if keepLimit > 0 {
                        lock.withLock {
                            buffer.append(data)
                            if buffer.count > keepLimit { buffer = buffer.suffix(keepLimit) }
                        }
                    }
                    onData?(data)
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                source.cancel()          // EOF or a read error
                return
            }
        }
        source.setCancelHandler { [group] in
            close(fd)
            onEnd?()
            group.leave()
        }
        source.resume()
    }

    func stop() { source.cancel() }

    func collected() -> Data { lock.withLock { buffer } }

    /// True if the pipe reached EOF (or was stopped) within `timeout` seconds.
    func finished(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let once = Once(cont)
            group.notify(queue: .global()) { once.resume(true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
    func resume(_ value: Bool) {
        let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in defer { cont = nil }; return cont }
        c?.resume(returning: value)
    }
}
