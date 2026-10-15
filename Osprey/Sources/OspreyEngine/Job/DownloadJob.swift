import CoreServices
import Foundation
import os

/// One download. It owns the lanes (one URLSession each, so each lane is its own keep-alive TCP
/// connection) and schedules them: ramp-up, halving split, neighbour absorption,
/// stall takeover, linear back-off and the damped limiter. Every lane runs on this actor,
/// like a single per-download event loop.
public actor DownloadJob {
    public nonisolated let id: UUID

    private struct Lane {
        var segmentID: Int?
        let session: URLSession
        var task: Task<Void, Never>?
        var lastActivity: TimeInterval
        /// While the limiter holds this lane, silence is not a stall (nor a phase timeout).
        var throttledUntil: TimeInterval = 0
        var receivedThisRequest: Int64 = 0
        var phase: LanePhase = .connecting
        var meter: SpeedMeter
        /// `urlEpoch` when the current request was built.
        var requestEpoch = 0
        var requestStartedAt: TimeInterval = 0
    }

    private struct LaneRequest {
        let urlRequest: URLRequest
        let session: URLSession
        let partial: Bool
        let offset: Int64
        /// Last byte this request asks for.
        let end: Int64
    }

    private let baseRequest: URLRequest
    private let folder: URL
    private var options: DownloadOptions
    private var state: DownloadState = .idle
    private var fileName: String
    private var resume: ResumeState?
    private var map: SegmentMap?
    private var file: PartFile?
    private var finalURL: URL?
    private var lanes: [Int: Lane] = [:]
    private var nextLaneID = 0
    private var ramp = RampController(maxConnections: 1, now: 0)
    private var meter = SpeedMeter(window: 3, startedAt: 0)
    private var peakSpeed: Double = 0
    private var controlTask: Task<Void, Never>?
    private var pendingWrites = 0
    /// Consecutive failed requests. Data on other, older connections does not reset it (see `noteProgress`).
    private var failureCount = 0
    private var lastFailureAt: TimeInterval = -.infinity
    private var spawnNotBefore: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var lastSave: TimeInterval = 0
    /// Bumped by every start() and pause() so a slow probe or pause can tell it has been superseded.
    private var generation = 0
    /// Bumped whenever `resume.url` is re-resolved from the original URL.
    private var urlEpoch = 0
    /// A re-probe of the original URL is running; no new requests start until it finishes.
    private var refreshingURL = false
    /// The URL was re-resolved and no request on the new URL has delivered data yet: another 401/403/410 is final.
    private var refreshEpisodeOpen = false
    /// Headers of the request the URL resolver last returned. Kept in memory only (never in the sidecar) and
    /// merged by `preparedRequest` with the same credential scoping as `options.headers`.
    private var refreshedHeaders: [String: String] = [:]
    /// The resolver call in flight, so pause() can cancel it.
    private var resolverRace: ResolveRace?

    public init(id: UUID = UUID(), request: URLRequest, folder: URL, options: DownloadOptions = DownloadOptions()) {
        self.id = id
        self.baseRequest = request
        self.folder = folder
        self.options = options
        self.fileName = request.url.map(FileNaming.name(from:)) ?? "download"
    }

    /// Rebuilds a download from its sidecar, paused. With `failure`, it shows that failure instead (a download that
    /// failed before the app quit) until `start()` resumes it.
    public init(id: UUID = UUID(), resuming saved: ResumeState, options: DownloadOptions = DownloadOptions(),
                failure: String? = nil) {
        self.id = id
        let request = URLRequest(url: saved.originalURL)
        var options = options
        // The sidecar never holds credentials; headers given in memory win over what it kept.
        options.headers = saved.headers.merging(options.headers) { _, live in live }
        self.baseRequest = request
        self.folder = saved.destination.deletingLastPathComponent()
        self.options = options
        self.fileName = saved.destination.lastPathComponent
        self.resume = saved
        self.map = saved.map
        self.state = failure.map { .failed($0) } ?? .paused
    }

    // MARK: Public API

    public func start() async {
        switch state {
        case .idle, .paused, .failed: break
        default: return
        }
        state = .probing
        generation += 1
        let token = generation
        do {
            var probe: ProbeResult
            var resolvedHeaders: [String: String]?
            do {
                guard let first = try await probeWithRetry(token: token, while: .probing) else { return }
                probe = first
            } catch let EngineError.httpStatus(code, _) where options.urlResolver != nil && [401, 403, 410].contains(code) {
                // The saved or given link expired (signed media URL): ask the resolver for a fresh one.
                guard state == .probing, generation == token,
                      let (fresh, headers) = try await resolveAndProbe(token: token, while: .probing) else { return }
                probe = fresh
                resolvedHeaders = headers
            }
            try prepareFiles(using: probe, resolvedHeaders: resolvedHeaders)
        } catch {
            // A probe that was paused or superseded must not fail the current state.
            guard state == .probing, generation == token else { return }
            fail(error)
            return
        }
        let now = uptime()
        state = .downloading
        startedAt = now
        lastSave = now
        failureCount = 0
        lastFailureAt = -.infinity
        spawnNotBefore = 0
        refreshingURL = false
        refreshEpisodeOpen = false
        meter = SpeedMeter(window: 3, startedAt: now)
        ramp = RampController(maxConnections: resume?.acceptsRanges == true ? options.maxConnections : 1, now: now)
        controlTask = Task { await self.controlLoop() }
    }

    public func pause() async {
        guard state == .downloading || state == .probing else { return }
        state = .paused
        controlTask?.cancel()
        controlTask = nil
        resolverRace?.cancel()
        resolverRace = nil
        for id in Array(lanes.keys) { removeLane(id) }
        generation += 1
        let token = generation
        let closing = file
        file = nil
        while pendingWrites > 0, generation == token { try? await Task.sleep(for: .milliseconds(10)) }
        let safe = map
        do {
            try await closing?.synchronize()
            if generation == token, let safe { save(safe) }   // only a map whose bytes are on disk
        } catch {}
        try? await closing?.close()
    }

    /// Stops the download and deletes its partial data (the part file and its resume sidecar).
    public func discard() async {
        await pause()
        guard let destination = resume?.destination ?? finalURL else { return }
        let partial = destination.appendingPathExtension("slpart")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: partial.appendingPathExtension("json"))
    }

    public func setSpeedLimit(_ bytesPerSecond: Double?) {
        options.speedLimit = bytesPerSecond
    }

    public func snapshot() -> DownloadSnapshot {
        let now = uptime()
        let laneSnapshots = lanes.sorted { $0.key < $1.key }.map { id, lane in
            var phase = lane.phase
            if phase == .receiving, silence(of: lane, at: now) > options.stallInterval { phase = .stalled }
            return LaneSnapshot(id: id, segmentID: lane.segmentID, phase: phase, bytesPerSecond: lane.meter.bytesPerSecond(at: now))
        }
        return DownloadSnapshot(state: state, fileName: fileName, totalSize: resume?.totalSize,
                                downloaded: map?.downloaded ?? 0,
                                bytesPerSecond: state == .downloading ? meter.bytesPerSecond(at: now) : 0,
                                segments: map?.segments ?? [], lanes: laneSnapshots,
                                acceptsRanges: resume?.acceptsRanges ?? false, etag: resume?.etag,
                                destination: finalURL ?? resume?.destination, lastModified: resume?.lastModified)
    }

    // MARK: Setup

    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func preparedRequest(url: URL, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = baseRequest
        request.url = url
        // Credentials stay with the origin the browser gave them for (scheme, host and port).
        let originalOrigin = HTTPHeaders.mayCarryCredentials(from: baseRequest.url, to: url)
        let layers = [options.headers, refreshedHeaders, extraHeaders]
        for headers in layers {
            for (field, value) in headers where originalOrigin || !HTTPHeaders.isSensitive(field) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        if !originalOrigin {
            for field in request.allHTTPHeaderFields?.keys ?? [:].keys where HTTPHeaders.isSensitive(field) {
                request.setValue(nil, forHTTPHeaderField: field)
            }
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// Probes the address the user gave (redirects are followed; the result carries the final URL).
    /// It obeys phaseTimeout like the lanes do, so a dead host fails fast instead of after 60 s.
    private func probeOriginalURL() async throws -> ProbeResult {
        try await probe(preparedRequest(url: baseRequest.url!))
    }

    private func probe(_ request: URLRequest) async throws -> ProbeResult {
        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = options.phaseTimeout
        let session = URLSession(configuration: probeConfig)
        defer { session.finishTasksAndInvalidate() }
        return try await Prober.probe(request, session: session)
    }

    /// Retries a probe that timed out or got 429/503 (honouring Retry-After), at most `probeAttempts` times;
    /// anything else (a refused connection, DNS, 4xx) fails at once.
    /// Returns nil once the job has moved on (paused or restarted), so the caller must not touch state.
    private func probeWithRetry(token: Int, while expected: DownloadState,
                                request: URLRequest? = nil) async throws -> ProbeResult? {
        var attempt = 0
        while true {
            do {
                let probe = if let request { try await self.probe(request) } else { try await probeOriginalURL() }
                guard state == expected, generation == token else { return nil }
                return probe
            } catch {
                guard state == expected, generation == token else { return nil }
                attempt += 1
                guard let delay = probeRetryDelay(after: error, attempt: attempt) else { throw error }
                try? await Task.sleep(for: .seconds(delay))
                guard state == expected, generation == token else { return nil }
            }
        }
    }

    private static func ensureUnchanged(_ probe: ProbeResult, matches saved: ResumeState) throws {
        if let size = probe.totalSize, size != saved.totalSize { throw EngineError.remoteFileChanged }
        if let old = saved.etag, let new = probe.etag, old != new { throw EngineError.remoteFileChanged }
        if saved.etag == nil, let old = saved.lastModified, let new = probe.lastModified, old != new {
            throw EngineError.remoteFileChanged
        }
    }

    private func prepareFiles(using probe: ProbeResult, resolvedHeaders: [String: String]? = nil) throws {
        if var existing = resume {
            if resolvedHeaders != nil {
                try Self.adoptResolved(probe, into: &existing)
            } else {
                try Self.ensureUnchanged(probe, matches: existing)
            }
            if let resolvedHeaders { refreshedHeaders = resolvedHeaders }
            existing.url = probe.finalURL               // signed links expire: always use the fresh target
            existing.acceptsRanges = probe.acceptsRanges
            if !probe.acceptsRanges { existing.map = SegmentMap(totalSize: existing.totalSize) }
            let partPath = existing.partURL.path(percentEncoded: false)
            let attributes = try? FileManager.default.attributesOfItem(atPath: partPath)
            let partSize = (attributes?[.size] as? NSNumber)?.int64Value
            if partSize != existing.totalSize {
                existing.map = SegmentMap(totalSize: existing.totalSize)   // a crash must not reuse the stale map
            }
            resume = existing
            save(existing.map)
            map = existing.map
            file = try PartFile(url: existing.partURL, size: existing.totalSize)
            return
        }
        guard let total = probe.totalSize, total > 0 else { throw EngineError.unknownSize }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferred = options.preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = preferred.flatMap { $0.isEmpty ? nil : ContentDisposition.sanitize($0) } ?? probe.suggestedFilename
        let destination = FileNaming.uniqueURL(in: folder, name: name)
        fileName = destination.lastPathComponent
        let fresh = ResumeState(url: probe.finalURL, destination: destination,
                                headers: HTTPHeaders.persistable(options.headers, isPrivate: options.isPrivate),
                                totalSize: total, etag: probe.etag, lastModified: probe.lastModified,
                                acceptsRanges: probe.acceptsRanges, map: SegmentMap(totalSize: total),
                                originalURL: baseRequest.url)
        resume = fresh
        map = fresh.map
        file = try PartFile(url: fresh.partURL, size: total)
        try ResumeStore.save(fresh)
        if let resolvedHeaders { refreshedHeaders = resolvedHeaders }
    }

    // MARK: Control loop

    private func controlLoop() async {
        while state == .downloading, !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func tick() async {
        guard state == .downloading, let map else { return }
        let now = uptime()
        if map.isComplete, pendingWrites == 0, lanes.values.allSatisfy({ $0.segmentID == nil }) {
            await complete()
            return
        }
        peakSpeed = max(peakSpeed, meter.bytesPerSecond(at: now))
        for (id, lane) in lanes where lane.segmentID != nil && silence(of: lane, at: now) > options.phaseTimeout {
            laneFailed(id, EngineError.timedOut)
        }
        if map.downloaded == 0, now - startedAt > options.giveUpWithoutData {
            fail(EngineError.timedOut)
            return
        }
        let busy = lanes.values.filter { $0.segmentID != nil }
        let productive = busy.filter { isProductive($0, at: now) }
        let brake = !SpeedLimiter.allowsRamp(peakSpeed: peakSpeed, limit: options.speedLimit)
        let allowed = ramp.update(now: now, active: busy.count, productive: productive.count, limiterBrake: brake)
        while state == .downloading, !refreshingURL, lanes.count < allowed, now >= spawnNotBefore, spawnLane() {}
        if now - lastSave >= 2, pendingWrites == 0, let safe = self.map {
            lastSave = now
            let captured = generation
            do {
                try await file?.synchronize()
                if state == .downloading, generation == captured { save(safe) }
            } catch {}                                 // keep the previous, fsynced snapshot
        }
    }

    /// Seconds since the lane last received data, not counting time the limiter held it.
    private func silence(of lane: Lane, at now: TimeInterval) -> TimeInterval {
        now < lane.throttledUntil ? 0 : max(0, now - max(lane.lastActivity, lane.throttledUntil))
    }

    private func isProductive(_ lane: Lane, at now: TimeInterval) -> Bool {
        lane.receivedThisRequest > 0 && silence(of: lane, at: now) <= options.stallInterval
    }

    private func currentMinPiece() -> Int64 {
        meter.bytesPerSecond(at: uptime()) > options.fastSpeedThreshold ? options.fastMinPiece : options.minPiece
    }

    // MARK: Lanes

    /// Creates a lane that already owns work; returns false (and creates nothing: no session, no lane
    /// number) when there is none.
    private func spawnLane() -> Bool {
        let id = nextLaneID
        guard let segmentID = pickWork(for: id, completed: nil) else { return false }
        nextLaneID += 1
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = options.phaseTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let now = uptime()
        lanes[id] = Lane(segmentID: segmentID, session: URLSession(configuration: config), task: nil,
                         lastActivity: now, meter: SpeedMeter(window: 3, startedAt: now))
        lanes[id]?.task = Task { await self.runLane(id) }
        return true
    }

    private func removeLane(_ id: Int) {
        guard let lane = lanes.removeValue(forKey: id) else { return }
        lane.task?.cancel()
        lane.session.invalidateAndCancel()
    }

    private func ownedSegments(excluding laneID: Int) -> Set<Int> {
        Set(lanes.filter { $0.key != laneID }.compactMap { $0.value.segmentID })
    }

    /// Gives the lane a segment: it keeps an unfinished one, otherwise gets new work from `pickWork`.
    private func assignWork(to laneID: Int) -> Bool {
        guard let lane = lanes[laneID], let map else { return false }
        if let current = lane.segmentID, map.segment(id: current)?.isComplete == false { return true }
        let assigned = pickWork(for: laneID, completed: lane.segmentID)
        lanes[laneID]?.segmentID = assigned
        return assigned != nil
    }

    /// Work for lane `laneID` (which may not exist yet). Order: absorb a barely-started neighbour of the
    /// segment it just completed, take an unowned or split segment, take over a stalled lane's segment.
    private func pickWork(for laneID: Int, completed: Int?) -> Int? {
        var assigned: Int?
        if let completed { assigned = absorbSuccessor(of: completed, for: laneID) }
        if assigned == nil, var map {
            assigned = map.nextAssignment(owned: ownedSegments(excluding: laneID), minPiece: currentMinPiece())
            self.map = map
        }
        if assigned == nil { assigned = takeOverStalledSegment(for: laneID) }
        return assigned
    }

    /// A lane that finished its range absorbs the next range if that range's owner has received < 50 bytes.
    private func absorbSuccessor(of completed: Int, for laneID: Int) -> Int? {
        guard let map, let successor = map.successor(of: completed), !successor.isComplete, successor.received < 50,
              let owner = lanes.first(where: { $0.key != laneID && $0.value.segmentID == successor.id }) else { return nil }
        removeLane(owner.key)
        return successor.id
    }

    /// Stall takeover: take the range of the lane that has been silent the longest (> stallInterval),
    /// but only while another connection is still receiving. The asking lane counts: a lane that just finished
    /// its range is the proof that the server still delivers.
    private func takeOverStalledSegment(for laneID: Int) -> Int? {
        let now = uptime()
        let others = lanes.filter { $0.key != laneID && $0.value.segmentID != nil }
        let stalled = others.filter { silence(of: $0.value, at: now) > options.stallInterval && $0.value.receivedThisRequest > 0 }
        guard let victim = stalled.min(by: { $0.value.lastActivity < $1.value.lastActivity }),
              let segmentID = victim.value.segmentID,
              lanes.contains(where: { $0.key != victim.key && isProductive($0.value, at: now) }) else { return nil }
        removeLane(victim.key)
        return segmentID
    }

    private func nextRequest(for laneID: Int) -> LaneRequest? {
        guard state == .downloading, !refreshingURL, let resume, assignWork(to: laneID),
              var lane = lanes[laneID], let segmentID = lane.segmentID else { return nil }
        if !resume.acceptsRanges, let segment = map?.segment(id: segmentID), segment.received > 0 {
            map = SegmentMap(totalSize: resume.totalSize)        // no ranges: restart from byte 0
        }
        guard let segment = map?.segment(id: segmentID) else { return nil }
        var request = preparedRequest(url: resume.url)
        var end = segment.end
        if resume.acceptsRanges {
            if let piece = limitedPiece() { end = min(end, segment.next + piece - 1) }
            request.setValue("bytes=\(segment.next)-\(end)", forHTTPHeaderField: "Range")
            let strongETag = resume.etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
            if let validator = strongETag ?? resume.lastModified {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }
        lane.receivedThisRequest = 0
        lane.requestEpoch = urlEpoch
        lane.requestStartedAt = uptime()
        lane.phase = .connecting
        lane.lastActivity = uptime()
        lanes[laneID] = lane
        return LaneRequest(urlRequest: request, session: lane.session, partial: resume.acceptsRanges,
                           offset: segment.next, end: end)
    }

    private func runLane(_ laneID: Int) async {
        while !Task.isCancelled, let request = nextRequest(for: laneID) {
            do {
                var accepted = false
                var endsWhereAsked = false             // the response body ends at the requested end
                let transfer = TransferStream.open(request.urlRequest, session: request.session, bufferCap: Self.laneBufferCap)
                receive: for try await event in transfer.events {
                    switch event {
                    case .response(let response):
                        endsWhereAsked = try validate(response, for: request)
                        accepted = true
                    case .data(let data):
                        guard accepted else { transfer.consumed(data.count); continue }
                        transfer.setBufferCap(laneBufferCap())
                        let keepGoing = try await accept(data, laneID: laneID)
                        transfer.consumed(data.count)
                        if let pause = throttleDelay(), pause > 0 {
                            // Stop reading from the socket for the pause, so the server is throttled too.
                            lanes[laneID]?.throttledUntil = uptime() + pause
                            transfer.suspendReading()
                            try await Task.sleep(for: .seconds(pause))
                            transfer.resumeReading()
                            let now = uptime()
                            lanes[laneID]?.throttledUntil = now
                            lanes[laneID]?.lastActivity = now
                        }
                        if !keepGoing {
                            // Everything requested has arrived: let the response end by itself so the keep-alive
                            // connection can be reused. Cancel the rest if the segment shrank under a split, or if
                            // the server sends past the requested end (it would be drained to EOF otherwise).
                            let segmentEnd = lanes[laneID]?.segmentID.flatMap { map?.segment(id: $0)?.end } ?? -1
                            if endsWhereAsked, segmentEnd >= request.end { continue }
                            break receive
                        }
                        // URLSession may keep reading while suspended; if the backlog still grows past twice
                        // the cap, drop this request (unwritten bytes are simply fetched again) to bound memory.
                        if request.partial, transfer.buffered > 2 * laneBufferCap() { break receive }
                    }
                }
                if Task.isCancelled { return }
                if lanes[laneID]?.receivedThisRequest == 0 {
                    laneFailed(laneID, EngineError.emptyResponse)
                    return
                }
                // A request that delivered everything it asked for proves the server works. One cut short
                // (split, backlog, dropped) proves nothing.
                if (lanes[laneID]?.receivedThisRequest ?? 0) >= request.end - request.offset + 1 { failureCount = 0 }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                laneFailed(laneID, error)
                return
            }
        }
        removeLane(laneID)
    }

    /// Throws unless the response serves the request; returns whether its body ends at the requested end.
    private func validate(_ response: HTTPURLResponse, for request: LaneRequest) throws -> Bool {
        let status = response.statusCode
        if request.partial {
            if status == 206 {
                let contentRange = response.value(forHTTPHeaderField: "Content-Range")
                guard HTTPHeaders.rangeStart(fromContentRange: contentRange) == request.offset else {
                    throw EngineError.rangeNotHonored
                }
                return HTTPHeaders.rangeEnd(fromContentRange: contentRange) == request.end
            }
            if status == 200 { throw EngineError.rangeNotHonored }
        } else if (200..<300).contains(status) {
            return true                                // the whole file, which ends where the segment does
        }
        let retryAfter = HTTPHeaders.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
        throw EngineError.httpStatus(status, retryAfter: retryAfter)
    }

    /// Records and writes a chunk; returns false once the lane's segment is complete (it may have shrunk after a split).
    private func accept(_ data: Data, laneID: Int) async throws -> Bool {
        guard state == .downloading, var lane = lanes[laneID], let segmentID = lane.segmentID,
              var map, let segment = map.segment(id: segmentID), let file else { return false }
        let offset = segment.next
        let accepted = map.record(Int64(data.count), for: segmentID)
        self.map = map
        let now = uptime()
        lane.receivedThisRequest += accepted
        lane.lastActivity = now
        lane.phase = .receiving
        lane.meter.add(accepted, at: now)
        lanes[laneID] = lane
        meter.add(accepted, at: now)
        if accepted > 0 {
            noteProgress(lane, at: now)
            if lane.requestEpoch == urlEpoch { refreshEpisodeOpen = false }
        }
        if accepted > 0 {
            pendingWrites += 1
            defer { pendingWrites -= 1 }
            do {
                try await file.write(data.prefix(Int(accepted)), at: offset)
            } catch {
                fail(EngineError.writeFailed(error.localizedDescription))
                throw CancellationError()
            }
        }
        return (self.map?.segment(id: segmentID)?.remaining ?? 0) > 0
    }

    /// Seconds of steady progress on one request after which a no-ranges download counts as healthy again.
    static let steadyProgressReset: TimeInterval = 5

    /// Resets the failure count only on evidence that new requests work: with ranges, a request opened after
    /// the last failure receives data; without ranges (every retry restarts at byte 0), a request has been
    /// receiving for `steadyProgressReset` seconds. Data on an older connection proves nothing about new ones.
    private func noteProgress(_ lane: Lane, at now: TimeInterval) {
        guard failureCount > 0, let resume else { return }
        if resume.acceptsRanges ? lane.requestStartedAt > lastFailureAt : now - lane.requestStartedAt >= Self.steadyProgressReset {
            failureCount = 0
        }
    }

    private func throttleDelay() -> TimeInterval? {
        guard let limit = options.speedLimit else { return nil }
        let now = uptime()
        let stats = meter.windowStats(at: now)
        return SpeedLimiter.pause(bytes: stats.bytes, elapsed: stats.elapsed, limit: limit, currentSpeed: meter.bytesPerSecond(at: now))
    }

    /// Unconsumed bytes per lane before its task stops reading from the socket.
    static let laneBufferCap = 8 << 20

    /// With a limit, each request asks for at most half a second of the allowed rate (≥ minPiece). URLSession's
    /// suspend() does not reliably stop socket reads, so bounded ranges are what keep the server from
    /// sending far ahead of the limiter. Without range support this falls back to suspend() alone.
    private func limitedPiece() -> Int64? {
        guard let limit = options.speedLimit, limit > 0 else { return nil }
        return max(options.minPiece, Int64(min(limit / 2, 1e15)))
    }

    /// With a limit, a lane buffers at most half a second of the allowed rate (≥ 64 KB), so pauses
    /// push back on the server instead of piling data up in memory.
    private func laneBufferCap() -> Int {
        guard let limit = options.speedLimit, limit > 0 else { return Self.laneBufferCap }
        return min(Self.laneBufferCap, max(65_536, Int(min(limit / 2, Double(Self.laneBufferCap)))))
    }

    private static let fatalURLErrors: Set<URLError.Code> = [
        .badURL, .unsupportedURL, .serverCertificateUntrusted,
        .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
        .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
    ]

    private func isFatal(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            // DNS failures are often transient (Wi-Fi handoff, sleep/wake): fatal only before any byte arrived.
            let dns = urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed
            return Self.fatalURLErrors.contains(urlError.code) || (dns && (map?.downloaded ?? 0) == 0)
        }
        if let engineError = error as? EngineError { return engineError.isFatal }
        return false
    }

    /// Probe attempts before giving up; a probe only retries timeouts and 429/503.
    static let probeAttempts = 5

    /// The back-off before probe retry `attempt`, or nil when the error is not worth retrying or the budget is spent.
    private func probeRetryDelay(after error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < Self.probeAttempts else { return nil }
        let retryable = switch error {
        case let urlError as URLError: urlError.code == .timedOut
        case EngineError.timedOut: true
        case EngineError.httpStatus(let code, _): code == 429 || code == 503
        default: false
        }
        return retryable ? backoff(after: error, attempt: attempt) : nil
    }

    /// Linear back-off (or Retry-After) before retry `attempt`, or nil once the retry budget is spent.
    private func backoff(after error: Error, attempt: Int) -> TimeInterval? {
        guard options.retry.canRetry(attempt: attempt) else { return nil }
        var retryAfter: TimeInterval?
        if case .httpStatus(_, let value)? = error as? EngineError { retryAfter = value }
        return options.retry.delay(afterAttempt: attempt, retryAfter: retryAfter)
    }

    private func laneFailed(_ laneID: Int, _ error: Error) {
        guard state == .downloading else { return }
        let now = uptime()
        let status: Int? = if case .httpStatus(let code, _)? = error as? EngineError { code } else { nil }
        let fresh = (lanes[laneID]?.receivedThisRequest ?? 0) == 0
        let productiveOthers = lanes.filter {
            $0.key != laneID && $0.value.segmentID != nil && isProductive($0.value, at: now)
        }.count
        let authRefusal = status.map { [401, 403, 410].contains($0) } ?? false
        // A request built for a URL that a refresh is replacing, or has replaced, says nothing about the server.
        let stale = (lanes[laneID]?.requestEpoch ?? urlEpoch) < urlEpoch
        if refreshingURL || stale, authRefusal || !isFatal(error) {
            removeLane(laneID)
            return
        }
        // A new connection refused while others are receiving: the server limits connections per client
        // (a per-server maximum). Stop ramping past the connections that work and keep going.
        let refusedExtra = fresh && productiveOthers > 0 && (status == 403 || !isFatal(error))
        if authRefusal, (map?.downloaded ?? 0) > 0 {
            if refreshEpisodeOpen {
                // The URL was just re-resolved and this request on it was refused before it delivered anything.
                // The re-probe proved that URL works, so with other lanes receiving this is a connection limit.
                if refusedExtra {
                    ramp.cap(at: productiveOthers)
                    retryLater(laneID, error)
                } else {
                    fail(error)
                }
                return
            }
            // The (signed) URL may have expired: re-resolve the original URL (once per failure episode) before
            // assuming a connection limit. A successful refresh lifts any cap.
            removeLane(laneID)
            refreshingURL = true
            let token = generation
            Task { await self.refreshURL(token: token, cause: error) }
            return
        }
        if refusedExtra {
            ramp.cap(at: productiveOthers)
            retryLater(laneID, error)
            return
        }
        if isFatal(error) {
            fail(error)
            return
        }
        retryLater(laneID, error)
    }

    /// Counts a failure, backs off new connections (linear, or Retry-After) and drops the lane;
    /// fails the job once the retry budget is spent.
    private func retryLater(_ laneID: Int?, _ error: Error) {
        failureCount += 1
        lastFailureAt = uptime()
        guard let delay = backoff(after: error, attempt: failureCount) else {
            fail(error)
            return
        }
        spawnNotBefore = max(spawnNotBefore, lastFailureAt + delay)
        if let laneID { removeLane(laneID) }
    }

    /// A resolver-supplied target is accepted when its size matches: another CDN edge may report other validators
    /// for the same bytes. The saved validators follow the new edge (or are cleared when it sends none), so the
    /// lanes' If-Range never carries a stale one.
    private static func adoptResolved(_ probe: ProbeResult, into saved: inout ResumeState) throws {
        if let size = probe.totalSize, size != saved.totalSize { throw EngineError.remoteFileChanged }
        saved.etag = probe.etag
        saved.lastModified = probe.lastModified
    }

    /// Runs the URL resolver (with `resolverTimeout`) and probes the request it returns, applying that request's
    /// headers on top of `options.headers` under the usual credential scoping. Returns nil once the job has moved on.
    /// Throws for a resolver failure or timeout, or a request without a URL.
    private func resolveAndProbe(token: Int, while expected: DownloadState) async throws -> (ProbeResult, [String: String])? {
        guard let resolver = options.urlResolver else { return nil }
        let race = ResolveRace()
        resolverRace = race
        let resolved: URLRequest
        do {
            resolved = try await race.run(resolver, timeout: options.resolverTimeout)
        } catch {
            if resolverRace === race { resolverRace = nil }
            throw error
        }
        if resolverRace === race { resolverRace = nil }
        guard state == expected, generation == token else { return nil }
        guard let url = resolved.url else { throw URLError(.badURL) }
        let headers = resolved.allHTTPHeaderFields ?? [:]
        guard let probe = try await probeWithRetry(token: token, while: expected,
                                                   request: preparedRequest(url: url, extraHeaders: headers)) else { return nil }
        return (probe, headers)
    }

    /// Re-probes the original URL, or asks the URL resolver for a fresh request. Lanes continue on the new final
    /// URL if the file is unchanged: same size, ETag and Last-Modified for a re-probe; only the same size for a
    /// resolver (and then with that request's headers).
    private func refreshURL(token: Int, cause: Error) async {
        do {
            var resolvedHeaders: [String: String]?
            let probed: ProbeResult?
            if options.urlResolver != nil {
                let result = try await resolveAndProbe(token: token, while: .downloading)
                probed = result?.0
                resolvedHeaders = result?.1
            } else {
                probed = try await probeWithRetry(token: token, while: .downloading)
            }
            guard let probe = probed, var current = resume else { return }
            if let resolvedHeaders {
                try Self.adoptResolved(probe, into: &current)
                refreshedHeaders = resolvedHeaders
            } else {
                try Self.ensureUnchanged(probe, matches: current)
            }
            current.url = probe.finalURL
            resume = current
            try? ResumeStore.save(current)             // keeps the last fsynced map, only the URL changes
            urlEpoch += 1
            refreshEpisodeOpen = true
            refreshingURL = false
            spawnNotBefore = 0
            ramp.uncap()                               // refusals on the expired URL were not a connection limit
        } catch {
            guard state == .downloading, generation == token else { return }
            refreshingURL = false
            if error as? EngineError == .remoteFileChanged {
                fail(error)
                return
            }
            // The re-probe was refused too, but lanes are still receiving: the server limits connections
            // (the probe is one more), so cap instead of failing. With nothing receiving, the URL is gone.
            let now = uptime()
            let productive = lanes.values.filter { $0.segmentID != nil && isProductive($0, at: now) }.count
            guard productive > 0 else {
                fail(cause)
                return
            }
            ramp.cap(at: productive)
            retryLater(nil, cause)
        }
    }

    private struct ResolverTimedOut: Error, LocalizedError {
        var errorDescription: String? { "The media link could not be refreshed in time." }
    }

    /// One resolver call raced against a timeout; `cancel()` abandons it. The resolver may ignore
    /// cancellation, so the continuation is resumed by whichever of result, timeout or cancel comes first.
    private final class ResolveRace: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<URLRequest, Error>?
        private var tasks: [Task<Void, Never>] = []
        private var early: Result<URLRequest, Error>?

        func cancel() { finish(.failure(CancellationError())) }

        private func finish(_ result: Result<URLRequest, Error>) {
            let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<URLRequest, Error>?, [Task<Void, Never>]) in
                guard !finished else { return (nil, []) }
                finished = true
                guard let continuation else { early = result; return (nil, tasks) }
                self.continuation = nil
                return (continuation, tasks)
            }
            tasks.forEach { $0.cancel() }
            continuation?.resume(with: result)
        }

        func run(_ resolver: @escaping @Sendable () async throws -> URLRequest, timeout: TimeInterval) async throws -> URLRequest {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLRequest, Error>) in
                let pending = lock.withLock { () -> Result<URLRequest, Error>? in
                    if let early { return early }
                    self.continuation = continuation
                    return nil
                }
                if let pending {
                    continuation.resume(with: pending)
                    return
                }
                let work = Task { [self] in
                    do { finish(.success(try await resolver())) } catch { finish(.failure(error)) }
                }
                let timer = Task { [self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    finish(.failure(ResolverTimedOut()))
                }
                let stop = lock.withLock { () -> Bool in
                    tasks = [work, timer]
                    return finished
                }
                if stop { work.cancel(); timer.cancel() }
            }
        }
    }

    // MARK: Ending

    private static let log = Logger(subsystem: "Osprey", category: "DownloadJob")

    /// Marks the file as downloaded from the web (`com.apple.quarantine`), so Gatekeeper checks it on first open.
    public static func quarantine(_ file: URL, data: URL, origin: URL) {
        var file = file
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Osprey",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: data,
            kLSQuarantineOriginURLKey as String: origin,
        ]
        do {
            try file.setResourceValues(values)
        } catch {
            log.error("Could not quarantine \(file.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Invariant: the sidecar must never claim bytes that are not on disk in the part file, so a map is
    /// saved only right after a successful synchronize() (tick, pause). fail() saves nothing: the sidecar
    /// already holds the last fsynced snapshot.
    private func save(_ map: SegmentMap) {
        guard var saved = resume else { return }
        saved.map = map
        resume = saved
        try? ResumeStore.save(saved)
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .failed(message)
        controlTask?.cancel()
        controlTask = nil
        for id in Array(lanes.keys) { removeLane(id) }
    }

    private func complete() async {
        guard let resume, let file else { return }
        state = .finishing
        controlTask = nil
        for id in Array(lanes.keys) { removeLane(id) }
        do {
            try await file.synchronize()
            try await file.close()
            self.file = nil
            var target = resume.destination
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                target = FileNaming.uniqueURL(in: target.deletingLastPathComponent(), name: target.lastPathComponent)
            }
            try FileManager.default.moveItem(at: resume.partURL, to: target)
            try? FileManager.default.removeItem(at: resume.stateURL)
            Self.quarantine(target, data: resume.url, origin: resume.originalURL)
            finalURL = target
            fileName = target.lastPathComponent
            state = .completed
        } catch {
            fail(EngineError.writeFailed(error.localizedDescription))
        }
    }
}
