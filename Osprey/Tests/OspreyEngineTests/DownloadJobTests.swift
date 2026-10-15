import CoreServices
import Foundation
import Testing
@testable import OspreyEngine

@Suite(.serialized) struct DownloadJobTests {
    /// Every test downloads under this root; each test starts by clearing what the previous one left.
    static let root = TestTemp.root.appending(path: "osprey-tests")

    init() {
        try? FileManager.default.removeItem(at: Self.root)
    }

    func tempFolder() -> URL {
        Self.root.appending(path: UUID().uuidString)
    }

    func isFailed(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test func forwardsCapturedHeadersAndUsesThePreferredName() async throws {
        let payload = testPayload(400_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.headers = ["Cookie": "session=abc", "Referer": "https://example.test/page", "User-Agent": "TestAgent/1.0"]
        options.preferredFilename = "../renamed.bin"
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        let destination = try #require(await job.snapshot().destination)
        #expect(destination.lastPathComponent == "renamed.bin")
        #expect(try Data(contentsOf: destination) == payload)
        #expect(!server.requests.isEmpty)
        for request in server.requests {
            #expect(request.headers["cookie"] == "session=abc")
            #expect(request.headers["referer"] == "https://example.test/page")
            #expect(request.headers["user-agent"] == "TestAgent/1.0")
        }
    }

    func sidecarURL(_ destination: URL) -> URL {
        destination.appendingPathExtension("slpart").appendingPathExtension("json")
    }

    @Test func sidecarNeverStoresCredentialsAndIsOwnerOnly() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.headers = ["Cookie": "session=topsecret", "authorization": "Bearer hunter2", "Referer": "https://example.test/p"]
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        let destination = try #require(await job.snapshot().destination)
        let path = sidecarURL(destination).path(percentEncoded: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains("topsecret"))
        #expect(!text.contains("hunter2"))
        #expect(text.contains("example.test"))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        // Resuming with the credentials in memory still sends them.
        server.config.chunkDelay = 0
        let before = server.requests.count
        let saved = try ResumeStore.load(from: sidecarURL(destination))
        let resumed = DownloadJob(resuming: saved, options: options)
        await resumed.start()
        try await waitUntil(timeout: .seconds(20)) { await resumed.snapshot().state == .completed }
        let after = server.requests.dropFirst(before)
        #expect(!after.isEmpty)
        for request in after {
            #expect(request.headers["cookie"] == "session=topsecret")
            #expect(request.headers["authorization"] == "Bearer hunter2")
        }
    }

    @Test func privateSidecarKeepsNoReferer() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.headers = ["Referer": "https://private.example/secret-page", "User-Agent": "TestAgent/1.0"]
        options.isPrivate = true
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        let destination = try #require(await job.snapshot().destination)
        let text = try String(contentsOfFile: sidecarURL(destination).path(percentEncoded: false), encoding: .utf8)
        #expect(!text.contains("private.example"))
        #expect(!text.lowercased().contains("referer"))
        #expect(text.contains("TestAgent"))
        // The request itself still carried the Referer.
        #expect(server.requests.allSatisfy { $0.headers["referer"] == "https://private.example/secret-page" })
    }

    @Test func credentialsStayOnTheOriginalHostAcrossRedirects() async throws {
        let payload = testPayload(400_000)
        let server = try TestHTTPServer(payload: payload)
        _ = try await server.start()
        defer { server.stop() }
        let port = server.url(path: "/").port!
        server.config.redirectTarget = "http://127.0.0.1:\(port)/file.bin"
        var options = DownloadOptions()
        options.headers = ["Cookie": "session=abc", "Authorization": "Bearer t", "Referer": "https://example.test/page", "User-Agent": "TestAgent/1.0"]
        let start = URL(string: "http://localhost:\(port)/redirect")!
        let job = DownloadJob(request: URLRequest(url: start), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        let redirected = server.requests.filter { $0.path == "/file.bin" }
        #expect(!redirected.isEmpty)
        for request in server.requests {
            #expect(request.headers["referer"] == "https://example.test/page")
            #expect(request.headers["user-agent"] == "TestAgent/1.0")
            if request.headers["host"]?.hasPrefix("127.0.0.1") == true {
                #expect(request.headers["cookie"] == nil)
                #expect(request.headers["authorization"] == nil)
            } else {
                #expect(request.headers["cookie"] == "session=abc")
            }
        }
        #expect(server.requests.contains { $0.headers["host"]?.hasPrefix("localhost") == true && $0.headers["cookie"] == "session=abc" })
    }

    @Test func credentialsDoNotFollowARedirectToAnotherPort() async throws {
        let payload = testPayload(200_000)
        let target = try TestHTTPServer(payload: payload)
        _ = try await target.start()
        defer { target.stop() }
        let front = try TestHTTPServer(payload: Data())
        _ = try await front.start()
        defer { front.stop() }
        front.config.redirectTarget = "http://localhost:\(target.url(path: "/").port!)/file.bin"   // same host, other port
        var options = DownloadOptions()
        options.headers = ["Cookie": "session=abc", "Authorization": "Bearer t", "User-Agent": "TestAgent/1.0"]
        let start = URL(string: "http://localhost:\(front.url(path: "/").port!)/redirect")!
        let job = DownloadJob(request: URLRequest(url: start), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        #expect(front.requests.contains { $0.headers["cookie"] == "session=abc" })
        #expect(!target.requests.isEmpty)
        for request in target.requests {
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["authorization"] == nil)
            #expect(request.headers["user-agent"] == "TestAgent/1.0")
        }
    }

    @Test func blankPreferredFilenameFallsBackToTheServerName() async throws {
        let payload = testPayload(100_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.preferredFilename = "  \n "
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        #expect(try #require(await job.snapshot().destination).lastPathComponent == "file.bin")
    }

    @Test func downloadsTheWholeFileByteForByte() async throws {
        let payload = testPayload(2_000_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        let snapshot = await job.snapshot()
        let destination = try #require(snapshot.destination)
        #expect(destination.lastPathComponent == "file.bin")
        #expect(snapshot.etag == "\"v1\"")
        #expect(snapshot.lastModified == "Tue, 13 Oct 2026 08:00:00 GMT")
        #expect(try Data(contentsOf: destination) == payload)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false) + ".slpart"))
    }

    // I5: finished files carry com.apple.quarantine like any browser download.
    @Test func completedFilesAreQuarantined() async throws {
        let payload = testPayload(300_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().state == .completed }
        let destination = try #require(await job.snapshot().destination)
        let properties = try #require(try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Osprey")
        #expect(properties[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        // The data/origin URLs go to the LaunchServices quarantine-events database and are not read back here.
    }

    @Test func rampsUpAndSplitsAcrossConnections() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.bytesPerChunk = 32_768
        config.chunkDelay = 0.01                      // ≈3.2 MB/s per connection
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(30)) { await job.snapshot().state == .completed }
        let snapshot = await job.snapshot()
        #expect(snapshot.segments.count >= 2)
        #expect(server.rangeRequests.count >= 3)      // probe + at least two lanes
        #expect(try Data(contentsOf: #require(snapshot.destination)) == payload)
    }

    @Test func fallsBackToOneConnectionWithoutRanges() async throws {
        let payload = testPayload(1_000_000)
        var config = TestHTTPServer.Config()
        config.supportsRanges = false
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        let snapshot = await job.snapshot()
        #expect(!snapshot.acceptsRanges)
        #expect(snapshot.segments.count == 1)
        #expect(try Data(contentsOf: #require(snapshot.destination)) == payload)
    }

    @Test func pausesAndResumesFromTheSidecar() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        let paused = await job.snapshot()
        #expect(paused.state == .paused)
        #expect(paused.downloaded < Int64(payload.count))
        let destination = try #require(paused.destination)
        let saved = try ResumeStore.load(from: destination.appendingPathExtension("slpart").appendingPathExtension("json"))
        #expect(saved.map.downloaded == paused.downloaded)

        server.config.chunkDelay = 0
        let before = server.rangeRequests.count
        let resumed = DownloadJob(resuming: saved)
        await resumed.start()
        try await waitUntil(timeout: .seconds(20)) { await resumed.snapshot().state == .completed }
        #expect(try Data(contentsOf: destination) == payload)
        let fresh = server.rangeRequests.dropFirst(before).filter { $0 != "bytes=0-0" }
        #expect(!fresh.isEmpty)
        #expect(fresh.allSatisfy { !$0.hasPrefix("bytes=0-") })
    }

    @Test func aRestoredFailureShowsItsMessageThenResumes() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        let destination = try #require(await job.snapshot().destination)
        let saved = try ResumeStore.load(from: sidecarURL(destination))

        let restored = DownloadJob(resuming: saved, failure: "The network connection was lost.")
        let shown = await restored.snapshot()
        #expect(shown.state == .failed("The network connection was lost."))
        #expect(shown.downloaded == saved.map.downloaded && shown.totalSize == Int64(payload.count))
        server.config.chunkDelay = 0
        let before = server.rangeRequests.count
        await restored.start()
        try await waitUntil(timeout: .seconds(20)) { await restored.snapshot().state == .completed }
        #expect(try Data(contentsOf: destination) == payload)
        let fresh = server.rangeRequests.dropFirst(before).filter { $0 != "bytes=0-0" }
        #expect(fresh.allSatisfy { !$0.hasPrefix("bytes=0-") })        // it continued, it didn't start over
    }

    @Test func resumesFromScratchWhenThePartFileIsMissing() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        let destination = try #require(await job.snapshot().destination)
        let saved = try ResumeStore.load(from: destination.appendingPathExtension("slpart").appendingPathExtension("json"))
        try FileManager.default.removeItem(at: destination.appendingPathExtension("slpart"))

        server.config.chunkDelay = 0
        let resumed = DownloadJob(resuming: saved)
        await resumed.start()
        try await waitUntil(timeout: .seconds(20)) { await resumed.snapshot().state == .completed }
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func pauseThenImmediateResumeStillCompletes() async throws {
        let payload = testPayload(4_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 100_000 }
        async let paused: Void = job.pause()
        await job.start()
        await paused
        if await job.snapshot().state == .paused { await job.start() }
        server.config.chunkDelay = 0
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        let destination = try #require(await job.snapshot().destination)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func refusesToResumeWhenTheRemoteFileChanged() async throws {
        let payload = testPayload(3_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 100_000 }
        await job.pause()
        let destination = try #require(await job.snapshot().destination)
        let saved = try ResumeStore.load(from: destination.appendingPathExtension("slpart").appendingPathExtension("json"))

        server.config.etag = "\"v2\""
        let resumed = DownloadJob(resuming: saved)
        await resumed.start()
        let state = await resumed.snapshot().state
        #expect(state == .failed(EngineError.remoteFileChanged.errorDescription ?? ""))
    }

    // C2: a redirect to a signed URL that rotates while paused.
    @Test func resumesAfterTheSignedURLRotates() async throws {
        let payload = testPayload(4_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.02
        config.signature = "1"
        let server = try TestHTTPServer(payload: payload, config: config)
        _ = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/redirect")), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(15)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        let destination = try #require(await job.snapshot().destination)
        let saved = try ResumeStore.load(from: destination.appendingPathExtension("slpart").appendingPathExtension("json"))
        #expect(saved.url.query() == "sig=1")
        #expect(saved.originalURL.path() == "/redirect")

        server.config.signature = "2"                 // the old link now answers 403
        server.config.chunkDelay = 0
        let resumed = DownloadJob(resuming: saved)
        await resumed.start()
        try await waitUntil(timeout: .seconds(20)) {
            let state = await resumed.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await resumed.snapshot().state == .completed)
        #expect(try Data(contentsOf: destination) == payload)
    }

    // C2: the signature rotates mid-download; lanes that open new requests get 403 and the job re-resolves.
    @Test func reResolvesTheURLWhenItExpiresMidDownload() async throws {
        let payload = testPayload(8_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01                      // ≈1.6 MB/s per connection
        config.signature = "1"
        let server = try TestHTTPServer(payload: payload, config: config)
        _ = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/redirect")), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        // Once the URL is re-resolved, the job must ramp up again: a refused request on the expired URL is
        // not a connection limit.
        var maxLanesAfterRefresh = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let snapshot = await job.snapshot()
            if snapshot.state == .completed || isFailed(snapshot.state) { break }
            if server.rangeRequests.filter({ $0 == "bytes=0-0" }).count >= 2 {
                maxLanesAfterRefresh = max(maxLanesAfterRefresh, snapshot.lanes.filter { $0.segmentID != nil }.count)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await job.snapshot().state == .completed)
        #expect(maxLanesAfterRefresh >= 2)
        #expect(server.requests.contains { $0.status == 403 })
        #expect(server.rangeRequests.filter { $0 == "bytes=0-0" }.count >= 2)   // the original URL was probed again
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }

    // I3: the probe retries 503 and honours Retry-After instead of failing at once.
    @Test func probeRetriesA503HonouringRetryAfter() async throws {
        let payload = testPayload(500_000)
        var config = TestHTTPServer.Config()
        config.overrides[1] = .init(status: 503, headers: ["Retry-After": "1"])
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(10)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await job.snapshot().state == .completed)
        let requests = server.requests
        #expect(requests.count >= 2)
        if requests.count >= 2 { #expect(requests[1].at - requests[0].at >= 0.9) }
    }

    // A refused connection is not worth retrying at probe time: the job fails promptly.
    @Test func refusedConnectionFailsQuickly() async throws {
        let server = try TestHTTPServer(payload: testPayload(1_000))
        let url = try await server.start()
        server.stop()                                 // nothing listens on the port any more
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        let clock = ContinuousClock()
        let started = clock.now
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { self.isFailed(await job.snapshot().state) }
        #expect(clock.now - started < .seconds(2))
    }

    // A server that ignores the requested range end: once a lane has its bytes it cancels the response
    // instead of draining the rest of the file.
    @Test func ignoredRangeEndIsNotDrainedToTheEnd() async throws {
        let payload = testPayload(8_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01                      // ≈1.6 MB/s per connection
        config.ignoreRangeEnd = true
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(20)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await job.snapshot().state == .completed)
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
        print("ignoreRangeEnd: server sent \(server.sentBytes) B for \(payload.count) B, ranges \(server.rangeRequests)")
        #expect(server.sentBytes < payload.count + payload.count / 4)
    }

    // I3: a server that allows only K connections caps the ramp instead of being hammered.
    @Test func connectionLimitedServerCapsTheRamp() async throws {
        let payload = testPayload(6_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01                      // ≈1.6 MB/s per connection
        config.maxConcurrentResponses = 2
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.retry = RetryPolicy(step: 0.2, cap: 0.2)   // a retry storm would show up many times
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        var maxLanesAfterCap = 0
        var firstRefusal: ContinuousClock.Instant?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let snapshot = await job.snapshot()
            if snapshot.state == .completed || isFailed(snapshot.state) { break }
            if firstRefusal == nil, server.requests.contains(where: { $0.status == 503 }) { firstRefusal = clock.now }
            // Lanes refused in the same tick exist until their 503s arrive; count once those are handled.
            if let firstRefusal, clock.now - firstRefusal > .milliseconds(300) {
                maxLanesAfterCap = max(maxLanesAfterCap, snapshot.lanes.filter { $0.segmentID != nil }.count)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = await job.snapshot()
        let rejected = server.requests.filter { $0.status == 503 }.count
        #expect(snapshot.state == .completed)
        #expect(rejected >= 1)
        // The lanes refused in the first over-limit tick, then no storm (a 0.2 s retry step would give ~10).
        // One more is tolerated: a lane that absorbs a just-started neighbour cancels two
        // responses and reconnects at once, and the server may not have counted those closes yet.
        #expect(rejected <= 3)
        #expect(maxLanesAfterCap <= 2)
        #expect(try Data(contentsOf: #require(snapshot.destination)) == payload)
    }

    // I3: a 403 on an extra lane after bytes have arrived may mean the URL expired: the job re-probes once,
    // finds the URL still valid, and keeps going without a cap.
    @Test func extraLaneRefusedWith403ReprobesAndContinues() async throws {
        let payload = testPayload(4_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01
        config.overrides[3] = .init(status: 403)      // 1 = probe, 2 = first lane, 3 = first extra lane
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(20)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await job.snapshot().state == .completed)
        #expect(server.rangeRequests.filter { $0 == "bytes=0-0" }.count == 2)   // one re-probe
        #expect(server.peakConcurrentResponses > 2)    // not capped after the refresh
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }

    // I3: a server that refuses every connection over 2 with 403 (the re-probe included) caps the ramp
    // and completes instead of failing as an expired URL.
    @Test func serverRefusingExtraConnectionsWith403CapsAndCompletes() async throws {
        let payload = testPayload(8_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01
        config.maxConcurrentResponses = 2
        config.refusalStatus = 403
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.retry = RetryPolicy(step: 0.2, cap: 0.2, maxAttempts: 20)
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(20)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await job.snapshot().state == .completed)
        let refusals = server.requests.filter { $0.status == 403 }.count
        print("403-limit: \(refusals) refusals, \(server.requests.count) requests, ranges \(server.rangeRequests)")
        #expect(refusals >= 1)
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }

    // I3: a no-ranges server that keeps dropping the connection must exhaust the retry budget, not loop forever.
    @Test func droppedConnectionsWithoutRangesExhaustRetries() async throws {
        let payload = testPayload(1_000_000)
        var config = TestHTTPServer.Config()
        config.supportsRanges = false
        config.truncateAfterBytes = 100_000
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.retry = RetryPolicy(step: 0.05, cap: 0.05, maxAttempts: 3)
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(8)) { self.isFailed(await job.snapshot().state) }
        #expect(server.requests.count <= 5)           // probe + 3 attempts (+1 slack)
    }

    // I3: a 503 with Retry-After on the first lane delays the retry by at least Retry-After.
    @Test func laneBacksOffForRetryAfter() async throws {
        let payload = testPayload(500_000)
        var config = TestHTTPServer.Config()
        config.overrides[2] = .init(status: 503, headers: ["Retry-After": "1"])
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(10)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await job.snapshot().state == .completed)
        let requests = server.requests
        #expect(requests.count >= 3)
        if requests.count >= 3 { #expect(requests[2].at - requests[1].at >= 0.9) }
    }

    // I3: a 503 with Retry-After on an extra lane doesn't fail the job; while others are receiving it caps the
    // ramp, so no replacement lane hammers the server (the first lane picks the range up when it is free).
    @Test func extraLane503CapsAndTheJobCompletes() async throws {
        let payload = testPayload(4_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01
        config.overrides[3] = .init(status: 503, headers: ["Retry-After": "1"])
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        var highestLaneID = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let snapshot = await job.snapshot()
            highestLaneID = max(highestLaneID, snapshot.lanes.map(\.id).max() ?? 0)
            if snapshot.state == .completed || isFailed(snapshot.state) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await job.snapshot().state == .completed)
        #expect(server.requests.filter { $0.status == 503 }.count == 1)
        #expect(highestLaneID <= 1)                   // lane 0, and lane 1 that was refused
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }

    // C1: the limiter must slow the socket, not just the disk writes.
    @Test func speedLimitThrottlesTheNetworkNotJustTheDisk() async throws {
        let payload = testPayload(12_000_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        let limit = 1_000_000.0
        options.speedLimit = limit
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        let seconds = 3.0
        var stalledSamples = 0
        for _ in 0..<Int(seconds * 10) {
            try await Task.sleep(for: .milliseconds(100))
            // A lane the limiter is holding is not stalled.
            stalledSamples += await job.snapshot().lanes.filter { $0.phase == .stalled }.count
        }
        let sent = server.sentBytes
        let written = await job.snapshot().downloaded
        await job.pause()
        print("limiter: server sent \(sent) B, written \(written) B in \(seconds) s at \(Int(limit)) B/s")
        #expect(written > 0)
        #expect(Double(sent) <= 2 * limit * seconds)
        #expect(stalledSamples == 0)
    }

    // I7: the probe hangs on a local server that never answers (no reliance on a blackholed address).
    @Test func pausingDuringAFailingProbeStaysPaused() async throws {
        var config = TestHTTPServer.Config()
        config.neverReply = true
        let server = try TestHTTPServer(payload: testPayload(1_000), config: config)
        let url = try await server.start()
        defer { server.stop() }
        var opts = DownloadOptions()
        opts.phaseTimeout = 1
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: opts)
        async let started: Void = job.start()
        try await waitUntil(timeout: .seconds(5)) { !server.requests.isEmpty }
        await job.pause()
        await started
        #expect(await job.snapshot().state == .paused)
    }

    // I6: one lane stalls mid-body; another lane takes its range over long before the 30 s phase timeout.
    @Test func stalledLaneIsTakenOver() async throws {
        let payload = testPayload(4_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01                      // ≈1.6 MB/s per connection
        config.stallRangeRequest = 2                  // 0 = probe, 1 = first lane, 2 = first extra lane
        config.stallAfterBytes = 65_536
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.maxConnections = 2                    // only the finishing lane itself can vouch for the server
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(15)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
        #expect(await job.snapshot().state == .completed)
        #expect(server.rangeRequests.count >= 4)
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }

    // I6: a lane that finishes its range and takes new work reuses its keep-alive connection.
    // The first lane is slow and the rest are fast, so fast lanes finish and split the slow lane's range.
    @Test func lanesReuseTheirConnections() async throws {
        let payload = testPayload(2_000_000)
        var config = TestHTTPServer.Config()
        config.rangeChunkDelays[1] = 0.05             // first lane ≈320 KB/s; later requests are unthrottled
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(20)) { await job.snapshot().state == .completed }
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
        let requests = server.requests
        #expect(server.connectionCount < server.rangeRequests.count)
        #expect(Set(requests.map(\.connection)).count < requests.count)
    }

    // I6: a 404 on the first request fails at once with the 404 message (no retries).
    @Test func notFoundFailsFast() async throws {
        var config = TestHTTPServer.Config()
        config.overrides[1] = .init(status: 404)
        let server = try TestHTTPServer(payload: testPayload(10_000), config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        let clock = ContinuousClock()
        let began = clock.now
        await job.start()
        #expect(clock.now - began < .seconds(1))
        #expect(await job.snapshot().state == .failed(EngineError.httpStatus(404, retryAfter: nil).errorDescription ?? ""))
        #expect(server.requests.count == 1)
    }

    // I6: the ETag changes mid-download; If-Range makes the server send the whole new file, which must fail
    // the job rather than splice two versions together.
    @Test func ifRangeMismatchMidDownloadFailsCleanly() async throws {
        let payload = testPayload(4_000_000)
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.etag = "\"v2\""
        try await waitUntil(timeout: .seconds(15)) { self.isFailed(await job.snapshot().state) }
        let snapshot = await job.snapshot()
        let allowed = [EngineError.rangeNotHonored, .remoteFileChanged].map { DownloadState.failed($0.errorDescription ?? "") }
        #expect(allowed.contains(snapshot.state))
        let destination = try #require(snapshot.destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    // I6: Phase 1 refuses downloads whose size the server doesn't report.
    @Test(arguments: [true, false]) func unknownSizeIsRefused(ranges: Bool) async throws {
        var config = TestHTTPServer.Config()
        config.supportsRanges = ranges
        config.unknownLength = true
        let server = try TestHTTPServer(payload: testPayload(100_000), config: config)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        #expect(await job.snapshot().state == .failed(EngineError.unknownSize.errorDescription ?? ""))
    }

    // U7: an idle spawn attempt creates no session and burns no lane number.
    @Test func idleSpawnAttemptsDoNotInflateLaneNumbers() async throws {
        let payload = testPayload(20_000)            // too small to split: extra lanes never find work
        var config = TestHTTPServer.Config()
        config.bytesPerChunk = 1_000
        config.chunkDelay = 0.1                       // ≈10 KB/s, so the ramp allows a 2nd lane meanwhile
        config.truncateAfterBytes = 15_000            // the first lane's connection drops after 1.5 s
        let server = try TestHTTPServer(payload: payload, config: config)
        let url = try await server.start()
        defer { server.stop() }
        var options = DownloadOptions()
        options.retry = RetryPolicy(step: 0.1, cap: 0.1)
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder(), options: options)
        await job.start()
        var highestLaneID = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            let snapshot = await job.snapshot()
            highestLaneID = max(highestLaneID, snapshot.lanes.map(\.id).max() ?? 0)
            if snapshot.state == .completed || isFailed(snapshot.state) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await job.snapshot().state == .completed)
        #expect(highestLaneID == 1)                   // lane 0, then its replacement lane 1
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }
}
