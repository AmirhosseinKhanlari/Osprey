import Darwin
import Foundation

/// Owns the Unix socket. Each connection carries one request and one reply.
public final class BridgeServer: @unchecked Sendable {
    /// Answers one request. A handler that changes anything (adds a download) must first win
    /// `gate.tryCommit()`; when it loses, the client was already told `internal` and the browser kept the file.
    public typealias Handler = @Sendable (BridgeRequest, CommitGate) async -> BridgeResponse

    private struct VersionProbe: Decodable { let v: Int }

    /// How long a handler may take before the client gets `.internalError` unless it committed.
    /// `BridgeTimeouts` keeps it below the client's reply wait, so a committed answer still reaches the browser.
    public static let handlerTimeout: TimeInterval = BridgeTimeouts.handler

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: BridgeResponse?
        var value: BridgeResponse? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// One start()..stop() run. The accept loop owns `fd` and closes it on exit, so the descriptor
    /// number can't be recycled while the loop might still call accept() on it.
    private final class Listener: @unchecked Sendable {
        let fd: Int32
        let wakeRead: Int32
        let wakeWrite: Int32
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false
        init(fd: Int32, wakeRead: Int32, wakeWrite: Int32) {
            self.fd = fd; self.wakeRead = wakeRead; self.wakeWrite = wakeWrite
        }
        var isStopped: Bool { lock.withLock { stopped } }
        func requestStop() {
            lock.withLock { stopped = true }
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)      // wakes poll() in the accept loop
        }
    }

    private let socketURL: URL
    private let verifier: any PeerVerifier
    private let handler: Handler
    private let replyTimeout: TimeInterval
    private let acceptFunction: @Sendable (Int32) -> Int32
    private let errorBackoffMilliseconds: Int32 = 100
    private let lock = NSLock()
    private var listener: Listener?
    private let acceptQueue = DispatchQueue(label: "OspreyBridge.accept")
    private let connectionQueue = DispatchQueue(label: "OspreyBridge.connection", attributes: .concurrent)

    public convenience init(socketURL: URL, verifier: any PeerVerifier, handler: @escaping Handler) {
        self.init(socketURL: socketURL, verifier: verifier, replyTimeout: BridgeServer.handlerTimeout,
                  acceptFunction: { Darwin.accept($0, nil, nil) }, handler: handler)
    }

    /// Internal seam for tests: a shorter handler timeout and a fault-injectable accept().
    init(socketURL: URL, verifier: any PeerVerifier, replyTimeout: TimeInterval,
         acceptFunction: @escaping @Sendable (Int32) -> Int32, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.verifier = verifier
        self.handler = handler
        self.replyTimeout = replyTimeout
        self.acceptFunction = acceptFunction
    }

    /// Starts listening. Calling it while already running throws `SocketError(EALREADY)` and changes nothing.
    public func start() throws {
        try lock.withLock {
            guard listener == nil else { throw SocketError(code: EALREADY, operation: "start") }
            let path = socketURL.path(percentEncoded: false)
            try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError(code: errno, operation: "socket") }
            func fail(_ code: Int32, _ operation: String, unlinkPath: Bool = false) -> SocketError {
                close(fd)
                if unlinkPath { unlink(path) }
                return SocketError(code: code, operation: operation)
            }
            var address: sockaddr_un
            do { address = try SocketIO.makeAddress(path) } catch { close(fd); throw error }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw fail(errno, "bind") }
            // 0600 is a security requirement: refuse to serve if it can't be applied.
            guard chmod(path, 0o600) == 0 else { throw fail(errno, "chmod", unlinkPath: true) }
            guard listen(fd, 16) == 0 else { throw fail(errno, "listen", unlinkPath: true) }
            // Non-blocking so a connection aborted between poll() and accept() can't block the loop.
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw fail(errno, "fcntl", unlinkPath: true) }
            var pipeFDs: [Int32] = [-1, -1]
            guard pipe(&pipeFDs) == 0 else { throw fail(errno, "pipe", unlinkPath: true) }
            let current = Listener(fd: fd, wakeRead: pipeFDs[0], wakeWrite: pipeFDs[1])
            listener = current
            acceptQueue.async { [self] in acceptLoop(current) }
        }
    }

    /// Stops listening and waits until the accept loop has exited and closed the socket,
    /// so nothing from this run can handle a request after `stop()` returns.
    public func stop() {
        let current = lock.withLock { () -> Listener? in
            defer { listener = nil }
            return listener
        }
        guard let current else { return }
        current.requestStop()
        current.finished.wait()
        unlink(socketURL.path(percentEncoded: false))
    }

    private func acceptLoop(_ current: Listener) {
        defer {
            close(current.fd)
            close(current.wakeRead)
            close(current.wakeWrite)
            current.finished.signal()
        }
        while !current.isStopped {
            var fds = [pollfd(fd: current.fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: current.wakeRead, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 {
                if errno != EINTR { backOff(current) }
                continue
            }
            if fds[1].revents != 0 || current.isStopped { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = acceptFunction(current.fd)
            if client < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                // EMFILE, ENFILE, ECONNABORTED, ENOMEM...: stay alive and retry shortly.
                NSLog("OspreyBridge: accept failed (errno %d); retrying", code)
                backOff(current)
                continue
            }
            if current.isStopped { close(client); return }
            connectionQueue.async { [self] in serve(client) }
        }
    }

    /// Sleeps briefly, but wakes immediately on stop().
    private func backOff(_ current: Listener) {
        var wake = pollfd(fd: current.wakeRead, events: Int16(POLLIN), revents: 0)
        _ = poll(&wake, 1, errorBackoffMilliseconds)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        // Accepted sockets inherit O_NONBLOCK from the listener on macOS; connections must block (with timeouts).
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        SocketIO.configure(client, timeout: 5)
        guard verifier.isAllowed(socket: client) else { return }
        let response: BridgeResponse
        do {
            guard let payload = try Frame.read(using: { try SocketIO.readExactly(client, $0) }) else { return }
            response = respond(to: payload)
        } catch {
            response = .failure(.badRequest)
        }
        guard let data = try? JSONEncoder().encode(response), let frame = try? Frame.encode(data) else { return }
        try? SocketIO.writeAll(client, frame)
    }

    private func respond(to payload: Data) -> BridgeResponse {
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: payload), probe.v != BridgeProtocol.version {
            return .failure(.unsupportedVersion)
        }
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: payload) else { return .failure(.badRequest) }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let gate = CommitGate()
        let handler = self.handler
        Task {
            box.value = await handler(request, gate)
            done.signal()
        }
        // This is a GCD worker, not a Swift-concurrency thread, so blocking it is safe.
        if done.wait(timeout: .now() + replyTimeout) == .timedOut {
            // Not committed yet: it never will be, so answering `internal` (the browser keeps the file) is safe.
            if gate.expire() { return .failure(.internalError) }
            // Committed just in time: the download is being added, so the browser must hear the real answer.
            done.wait()
        }
        return box.value ?? .failure(.internalError)
    }
}
