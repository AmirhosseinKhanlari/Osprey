import Darwin
import Foundation

public enum BridgeClientError: Error, Equatable {
    case unavailable
    case notRunning   // hello only: nothing is listening and a hello never launches the app
    case noReply
    case untrustedServer   // something other than Osprey owns the socket
}

/// Sends one request to the app's socket. A capture or media request launches the app first if nothing is listening; a hello never does.
/// The launcher returns false when there is no app to launch, which fails the call immediately.
public struct BridgeClient: Sendable {
    /// How the client spends a capture's time budget (see `BridgeTimeouts`).
    public struct Timing: Sendable, Equatable {
        /// The whole call, launch included. It stays below the extensions' 8 s capture timeout.
        public var budget: TimeInterval
        /// The longest the client polls for the socket after launching the app.
        public var launchWait: TimeInterval
        /// The longest the client waits for the reply. It stays above the server's handler timeout.
        public var replyWait: TimeInterval

        public init(budget: TimeInterval = BridgeTimeouts.captureBudget, launchWait: TimeInterval = BridgeTimeouts.launchWait,
                    replyWait: TimeInterval = BridgeTimeouts.replyWait) {
            self.budget = budget
            self.launchWait = launchWait
            self.replyWait = replyWait
        }

        public static let standard = Timing()

        /// When to stop polling for a launched app: early enough that a full reply wait still fits the budget.
        func launchDeadline(from start: TimeInterval) -> TimeInterval {
            start + max(0, min(launchWait, budget - replyWait))
        }

        /// The socket's receive timeout: the reply wait, cut short by what is left of the budget.
        func receiveTimeout(elapsed: TimeInterval) -> TimeInterval {
            max(0.05, min(replyWait, budget - elapsed))
        }
    }

    public let socketURL: URL
    public let timing: Timing
    public let launcher: (@Sendable () -> Bool)?
    /// Checks that the process owning the socket is Osprey before anything (cookies included) is sent.
    public let serverVerifier: any PeerVerifier

    public init(socketURL: URL = BridgeLocation.defaultSocketURL(), timing: Timing = .standard,
                serverVerifier: any PeerVerifier = BridgeClient.defaultServerVerifier(),
                launcher: (@Sendable () -> Bool)? = { AppLauncher.launchOsprey() }) {
        self.socketURL = socketURL
        self.timing = timing
        self.serverVerifier = serverVerifier
        self.launcher = launcher
    }

    /// Osprey itself, signed by our team. Unsigned SwiftPM development runs can opt out in Debug builds
    /// with `OSPREY_BRIDGE_INSECURE=1`, the same switch the app uses for its peer check.
    public static func defaultServerVerifier() -> any PeerVerifier {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OSPREY_BRIDGE_INSECURE"] == "1" { return AllowAllPeerVerifier() }
        #endif
        return CodeSignaturePeerVerifier(teamID: BridgeLocation.teamID, identifiers: [BridgeLocation.appBundleID])
    }

    public func send(_ request: BridgeRequest) throws -> BridgeResponse {
        let start = ProcessInfo.processInfo.systemUptime
        let fd = try connectOrLaunch(mayLaunch: request.type != .hello, deadline: timing.launchDeadline(from: start))
        defer { close(fd) }
        guard serverVerifier.isAllowed(socket: fd) else { throw BridgeClientError.untrustedServer }
        SocketIO.configure(fd, timeout: timing.receiveTimeout(elapsed: ProcessInfo.processInfo.systemUptime - start))
        let frame = try Frame.encode(try JSONEncoder().encode(request))
        let reply: Data
        do {
            try SocketIO.writeAll(fd, frame)
            guard let received = try Frame.read(using: { try SocketIO.readExactly(fd, $0) }) else { throw BridgeClientError.noReply }
            reply = received
        } catch let error as SocketError where error.code == EPIPE || error.code == ECONNRESET || error.code == ENOTCONN {
            // the server hung up on us (e.g. it rejected this peer; on macOS a write can see ENOTCONN if the close is very fast)
            throw BridgeClientError.noReply
        } catch let error as SocketError where error.code == EAGAIN || error.code == EWOULDBLOCK {
            // the reply wait ran out: give up before the extension does, so the browser keeps its download
            throw BridgeClientError.noReply
        }
        return try JSONDecoder().decode(BridgeResponse.self, from: reply)
    }

    /// True when nothing is listening yet (no socket file, or a stale one): worth launching the app and polling.
    private static func nothingListening(_ error: any Error) -> Bool {
        guard let error = error as? SocketError, error.operation == "connect" else { return false }
        return error.code == ENOENT || error.code == ECONNREFUSED
    }

    private func connectOrLaunch(mayLaunch: Bool, deadline: TimeInterval) throws -> Int32 {
        do { return try connect() } catch where Self.nothingListening(error) {}
        // Only a capture or media request may start the app; a hello (periodic rules refresh) must never relaunch a quit app.
        guard mayLaunch else { throw BridgeClientError.notRunning }
        guard let launcher else { throw BridgeClientError.unavailable }
        guard launcher() else { throw BridgeClientError.unavailable }   // not installed: don't poll
        while ProcessInfo.processInfo.systemUptime < deadline {
            usleep(100_000)
            do { return try connect() } catch where Self.nothingListening(error) {}
        }
        throw BridgeClientError.unavailable
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(code: errno, operation: "socket") }
        var address: sockaddr_un
        do { address = try SocketIO.makeAddress(socketURL.path(percentEncoded: false)) } catch { close(fd); throw error }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError(code: code, operation: "connect")
        }
        return fd
    }
}
