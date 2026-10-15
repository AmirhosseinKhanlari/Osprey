import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 with keep-alive, Range/206, ETag/If-Range and throttling,
/// plus fault modes (stalls, silent hangs, status overrides, connection limits, expiring signed URLs).
final class TestHTTPServer: @unchecked Sendable {
    struct Override: Sendable {
        var status: Int
        var headers: [String: String] = [:]
    }

    struct Config: Sendable {
        var supportsRanges = true
        var etag = "\"v1\""
        var bytesPerChunk = 16_384
        var chunkDelay: TimeInterval = 0
        /// Per-request `chunkDelay`, keyed by 0-based index into `rangeRequests` (0 is the probe).
        var rangeChunkDelays: [Int: TimeInterval] = [:]
        /// Report no total size (`Content-Range: …/*`, or no Content-Length and close-delimited bodies).
        var unknownLength = false
        /// Accept requests but never answer them.
        var neverReply = false
        /// Answer the Nth request (1-based, counting every request including the probe) with this status.
        var overrides: [Int: Override] = [:]
        /// Stop sending (and keep the connection open) after `stallAfterBytes` of the Nth 206 range request
        /// (0-based index into `rangeRequests`, so the probe is 0) or of the first range request starting at `stallRangeStart`.
        var stallRangeRequest: Int?
        var stallRangeStart: Int?
        var stallAfterBytes = 65_536
        /// Send this many body bytes, then close the connection (simulates a server that drops connections).
        var truncateAfterBytes: Int?
        /// At most this many responses in flight; extra requests get 503 and the connection is closed.
        var maxConcurrentResponses: Int?
        /// The status for requests over `maxConcurrentResponses` (503 sends `Retry-After: 0`).
        var refusalStatus = 503
        /// When set, `/file.bin` needs `?sig=<signature>` (else 403) and `/redirect` answers 302 to the signed URL.
        var signature: String?
        /// Answer range requests from the requested start to the end of the file, ignoring the requested end
        /// (`Content-Range` reports what is actually sent).
        var ignoreRangeEnd = false
        /// When set, `/redirect` answers 302 to this absolute URL (e.g. the same server under another host name).
        var redirectTarget: String?
    }

    struct Request: Sendable {
        let number: Int
        let path: String
        let range: String?
        let status: Int
        let at: TimeInterval
        let connection: Int
        let headers: [String: String]
    }

    let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")
    private let lock = NSLock()
    private var storedConfig: Config
    private var storedRanges: [String] = []
    private var storedRequests: [Request] = []
    private var storedSent = 0
    private var storedConnections = 0
    private var inFlight = 0
    private var maxInFlight = 0
    private var stalledOnce = false
    private var open: [Int: NWConnection] = [:]

    var config: Config {
        get { lock.withLock { storedConfig } }
        set { lock.withLock { storedConfig = newValue } }
    }
    /// Range headers that were answered with 206.
    var rangeRequests: [String] { lock.withLock { storedRanges } }
    /// Every request, in arrival order.
    var requests: [Request] { lock.withLock { storedRequests } }
    /// Body bytes handed to the network stack.
    var sentBytes: Int { lock.withLock { storedSent } }
    /// TCP connections accepted.
    var connectionCount: Int { lock.withLock { storedConnections } }
    /// Most responses that were ever in flight at once (rejected ones excluded).
    var peakConcurrentResponses: Int { lock.withLock { maxInFlight } }

    init(payload: Data, config: Config = Config()) throws {
        self.payload = payload
        self.storedConfig = config
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        let gate = OnceGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if gate.open() { continuation.resume() }
                case .failed(let error): if gate.open() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        return url(path: "/file.bin")
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    func stop() {
        listener.cancel()
        let connections = lock.withLock { () -> [NWConnection] in
            defer { open.removeAll() }
            return Array(open.values)
        }
        connections.forEach { $0.cancel() }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func accept(_ connection: NWConnection) {
        let id = lock.withLock { () -> Int in
            storedConnections += 1
            open[storedConnections] = connection
            return storedConnections
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.lock.withLock { _ = self?.open.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let rest = Data(buffer[end.upperBound...])
                self.respond(connection, id: id, head: head) { self.receive(connection, id: id, buffer: rest) }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, id: id, buffer: buffer)
            }
        }
    }

    /// Cancels the connection once the client closes it (used while we deliberately stay silent).
    private func watchForClose(_ connection: NWConnection, then release: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                release()
                connection.cancel()
            } else {
                self?.watchForClose(connection, then: release)
            }
        }
    }

    private func respond(_ connection: NWConnection, id: Int, head: String, graced: Bool = false,
                         then next: @escaping @Sendable () -> Void) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let config = self.config
        if let limit = config.maxConcurrentResponses, !graced, lock.withLock({ inFlight >= limit }) {
            // A client that just closed a connection may open the next one before we notice the close;
            // like a real server, give closes a moment to land before counting this one as over the limit.
            queue.asyncAfter(deadline: .now() + 0.1) {
                self.respond(connection, id: id, head: head, graced: true, then: next)
            }
            return
        }
        let (number, rejected) = lock.withLock { () -> (Int, Bool) in
            let number = storedRequests.count + 1
            if let limit = config.maxConcurrentResponses, inFlight >= limit { return (number, true) }
            return (number, false)
        }
        func record(_ status: Int, range: String? = nil) {
            lock.withLock {
                storedRequests.append(Request(number: number, path: target, range: headers["range"], status: status,
                                              at: now(), connection: id, headers: headers))
                if let range { storedRanges.append(range) }
            }
        }

        if config.neverReply {
            record(0)
            watchForClose(connection) {}
            return
        }
        if rejected {
            record(config.refusalStatus)
            let extra = config.refusalStatus == 503 ? "Retry-After: 0\r\n" : ""
            sendEmpty(connection, status: "\(config.refusalStatus) Refused", extra: extra, close: true)
            return
        }
        if let override = config.overrides[number] {
            record(override.status)
            let extra = override.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            sendEmpty(connection, status: "\(override.status) Status", extra: extra, close: false, then: next)
            return
        }
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
        if path == "/redirect", let target = config.redirectTarget {
            record(302)
            sendEmpty(connection, status: "302 Found", extra: "Location: \(target)\r\n", close: false, then: next)
            return
        }
        if let signature = config.signature {
            if path == "/redirect" {
                record(302)
                sendEmpty(connection, status: "302 Found", extra: "Location: /file.bin?sig=\(signature)\r\n", close: false, then: next)
                return
            }
            if query != "sig=\(signature)" {
                record(403)
                sendEmpty(connection, status: "403 Forbidden", extra: "", close: false, then: next)
                return
            }
        }

        let total = payload.count
        var status = "200 OK"
        var code = 200
        var start = 0
        var end = total - 1
        var extra = "Accept-Ranges: \(config.supportsRanges ? "bytes" : "none")\r\nETag: \(config.etag)\r\n"
            + "Last-Modified: Tue, 13 Oct 2026 08:00:00 GMT\r\n"
        var rangeIndex: Int?
        if config.supportsRanges, let range = headers["range"], let parsed = Self.parseRange(range, total: total),
           headers["if-range"] == nil || headers["if-range"] == config.etag {
            rangeIndex = lock.withLock { storedRanges.count }
            (start, end) = parsed
            if config.ignoreRangeEnd { end = total - 1 }
            status = "206 Partial Content"
            code = 206
            extra += "Content-Range: bytes \(start)-\(end)/\(config.unknownLength ? "*" : String(total))\r\n"
        }
        record(code, range: code == 206 ? headers["range"] : nil)
        let body = payload.subdata(in: start..<(end + 1))
        var limit = body.count
        var stall = false
        if let index = rangeIndex {
            let matches = index == config.stallRangeRequest || start == config.stallRangeStart
            if matches, lock.withLock({ () -> Bool in defer { stalledOnce = true }; return !stalledOnce }) {
                limit = min(config.stallAfterBytes, body.count)
                stall = true
            }
        }
        var closeAfter = false
        if let truncate = config.truncateAfterBytes, truncate < body.count {
            limit = truncate
            closeAfter = true
        }
        let closeDelimited = config.unknownLength && code == 200
        let lengthHeader = closeDelimited ? "" : "Content-Length: \(body.count)\r\n"
        let connectionHeader = closeDelimited ? "close" : "keep-alive"
        let header = "HTTP/1.1 \(status)\r\n\(lengthHeader)Content-Type: application/octet-stream\r\nConnection: \(connectionHeader)\r\n\(extra)\r\n"
        lock.withLock {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        let release = Release { [weak self] in self?.lock.withLock { self?.inFlight -= 1 } }
        let (stalls, closes) = (stall, closeAfter)
        var bodyConfig = config
        if let index = rangeIndex, let delay = config.rangeChunkDelays[index] { bodyConfig.chunkDelay = delay }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        sendBody(connection, body: body.prefix(limit), offset: 0, config: bodyConfig, release: release) {
            release.fire()
            if stalls {
                self.watchForClose(connection) {}
            } else if closes || closeDelimited {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                next()
            }
        }
    }

    private func sendEmpty(_ connection: NWConnection, status: String, extra: String, close: Bool,
                           then next: (@Sendable () -> Void)? = nil) {
        let header = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: \(close ? "close" : "keep-alive")\r\n\(extra)\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            if close {
                connection.cancel()
            } else {
                next?()
            }
        })
    }

    private func sendBody(_ connection: NWConnection, body: Data, offset: Int, config: Config, release: Release,
                          then next: @escaping @Sendable () -> Void) {
        guard offset < body.count else { next(); return }
        let chunkEnd = min(offset + config.bytesPerChunk, body.count)
        let chunk = body.subdata(in: (body.startIndex + offset)..<(body.startIndex + chunkEnd))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                release.fire()
                return
            }
            self.lock.withLock { self.storedSent += chunk.count }
            if config.chunkDelay > 0 {
                self.queue.asyncAfter(deadline: .now() + config.chunkDelay) {
                    self.sendBody(connection, body: body, offset: chunkEnd, config: config, release: release, then: next)
                }
            } else {
                self.sendBody(connection, body: body, offset: chunkEnd, config: config, release: release, then: next)
            }
        })
    }

    static func parseRange(_ value: String, total: Int) -> (Int, Int)? {
        guard value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? total - 1, total - 1)
        guard start <= end, start < total else { return nil }
        return (start, end)
    }
}

/// Runs its action at most once.
final class Release: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func fire() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.action = nil }
            return self.action
        }
        action?()
    }
}

/// Lets exactly one caller through (resumes a continuation once).
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func open() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

func testPayload(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ ($0 >> 8) &+ 7) })
}
