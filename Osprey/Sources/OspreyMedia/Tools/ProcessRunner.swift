import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
}

/// Runs an external tool with an argument array (never a shell).
public enum ProcessRunner {
    /// The parent's environment minus every `PYTHON*` key (a user's Python setup can't break the tool) and every
    /// `DYLD_*` key (nothing can inject a library into it).
    static func sanitizedEnvironment(_ base: [String: String]) -> [String: String] {
        base.filter { !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD_") }
    }

    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                           environment: [String: String]? = nil) async throws -> ProcessResult {
        // The child leads its own process group, so a timeout or cancellation takes its helpers (ffmpeg, …) down too.
        let child = try ChildProcess.spawn(executable: executable, arguments: arguments,
                                           environment: sanitizedEnvironment(environment ?? ProcessInfo.processInfo.environment))
        defer { MediaCleanup.shared.unregister(child) }          // every path below has finished with the group
        let out = PipeReader(fd: child.stdoutFD, keep: .max)
        let err = PipeReader(fd: child.stderrFD, keep: .max)
        let flags = Flags()

        return try await withTaskCancellationHandler {
            let timer = Task {
                try await Task.sleep(for: .seconds(timeout))
                flags.markTimedOut()
                child.terminateGroupThenKill()
            }
            let status = await child.waitForExit()
            timer.cancel()
            if flags.timedOut || flags.cancelled || Task.isCancelled {
                child.signalGroup(SIGKILL)
                out.stop(); err.stop()
                if flags.timedOut { throw MediaError.timedOut }
                throw CancellationError()
            }
            // A normal exit normally closes the pipes at once. A grandchild that kept them open gets 2 s, then the group is killed.
            let deadline = Date().addingTimeInterval(2)
            var drained = await out.finished(timeout: 2)
            drained = await err.finished(timeout: max(0.05, deadline.timeIntervalSinceNow)) && drained
            if !drained {
                child.signalGroup(SIGKILL)
                _ = await out.finished(timeout: 1)
                _ = await err.finished(timeout: 1)
                out.stop(); err.stop()
            }
            return ProcessResult(status: status, stdout: out.collected(), stderr: String(decoding: err.collected(), as: UTF8.self))
        } onCancel: {
            flags.markCancelled()
            child.terminateGroupThenKill()
        }
    }
}

/// Lock-protected flags shared with the timer and the cancellation handler.
private final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false, _cancelled = false
    var timedOut: Bool { lock.withLock { _timedOut } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func markTimedOut() { lock.withLock { _timedOut = true } }
    func markCancelled() { lock.withLock { _cancelled = true } }
}
