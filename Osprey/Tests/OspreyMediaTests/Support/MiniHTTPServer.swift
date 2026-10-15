import Foundation
import Network

/// Tiny HTTP/1.1 server on 127.0.0.1 serving fixed bodies by path (404 otherwise). Trimmed from the engine tests' TestHTTPServer.
final class MiniHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MiniHTTPServer")
    private let lock = NSLock()
    private var bodies: [String: Data]
    private var paths: [String] = []
    /// Paths answered with this status line (e.g. "429 Too Many Requests") and an empty body.
    private var statuses: [String: String]

    init(bodies: [String: Data], statuses: [String: String] = [:]) throws {
        self.bodies = bodies
        self.statuses = statuses
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    /// Paths requested so far, in arrival order.
    var requestedPaths: [String] { lock.withLock { paths } }

    func setBody(_ data: Data, for path: String) { lock.withLock { bodies[path] = data } }

    func start() async throws {
        let gate = MiniOnceGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if gate.open() { continuation.resume() }
                case .failed(let error): if gate.open() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func url(path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(connection, head: head)
                self.receive(connection, buffer: Data(buffer[end.upperBound...]))
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let path = head.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let (body, forced) = lock.withLock { () -> (Data?, String?) in
            paths.append(path)
            return (bodies[path], statuses[path])
        }
        let status = forced ?? (body == nil ? "404 Not Found" : "200 OK")
        let payload = forced == nil ? (body ?? Data()) : Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\nContent-Type: application/octet-stream\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in })
    }
}

private final class MiniOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func open() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
