import Foundation
import Testing
@testable import OspreyEngine

extension URLRequest {
    /// A request whose `url` is nil (a resolver bug the engine must survive).
    func withoutURL() -> URLRequest { var copy = self; copy.url = nil; return copy }
}

@Suite(.serialized) struct URLResolverTests {
    static let root = TestTemp.root.appending(path: "osprey-resolver-tests")

    init() {
        try? FileManager.default.removeItem(at: Self.root)
    }

    func tempFolder() -> URL { Self.root.appending(path: UUID().uuidString) }

    func isFailed(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// A server whose `/file.bin?sig=1` serves the payload slowly; rotating the signature expires the link.
    func signedServer(_ payload: Data) async throws -> TestHTTPServer {
        var config = TestHTTPServer.Config()
        config.chunkDelay = 0.01
        config.signature = "1"
        let server = try TestHTTPServer(payload: payload, config: config)
        _ = try await server.start()
        return server
    }

    func finishedOrFailed(_ job: DownloadJob, seconds: Int = 25) async throws {
        try await waitUntil(timeout: .seconds(seconds)) {
            let state = await job.snapshot().state
            return state == .completed || self.isFailed(state)
        }
    }

    @Test func resolverRefreshesAnExpiredURLAndItsHeadersReachTheLanes() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        var options = DownloadOptions()
        let freshURL = server.url(path: "/file.bin?sig=2")
        options.urlResolver = {
            var request = URLRequest(url: freshURL)
            request.setValue("t2", forHTTPHeaderField: "X-Token")
            return request
        }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        try await finishedOrFailed(job)
        #expect(await job.snapshot().state == .completed)
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
        let requests = server.requests
        let firstExpired = try #require(requests.firstIndex { $0.status == 403 })
        let after = requests[firstExpired...].filter { $0.path.hasSuffix("sig=2") }
        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0.headers["x-token"] == "t2" })
        #expect(requests.filter { $0.path.hasSuffix("sig=1") }.allSatisfy { $0.headers["x-token"] == nil })
        #expect(requests.contains { $0.path.hasSuffix("sig=2") && $0.status == 206 })
    }

    @Test func resolverTargetWithADifferentSizeFailsAsChanged() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        let other = try TestHTTPServer(payload: testPayload(3_000_000))
        _ = try await other.start()
        defer { server.stop(); other.stop() }
        var options = DownloadOptions()
        let otherURL = other.url(path: "/file.bin")
        options.urlResolver = { URLRequest(url: otherURL) }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        try await finishedOrFailed(job)
        let state = await job.snapshot().state
        #expect(state == .failed(EngineError.remoteFileChanged.errorDescription ?? ""))
    }

    @Test func aThrowingResolverFailsLikeAFailedReprobe() async throws {
        struct ResolverFailure: Error {}
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        var options = DownloadOptions()
        options.urlResolver = { throw ResolverFailure() }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        try await finishedOrFailed(job)
        let state = await job.snapshot().state
        #expect(isFailed(state))
        #expect(!server.requests.contains { $0.path.hasSuffix("sig=2") })
    }

    /// Counts resolver calls from a @Sendable closure.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    @Test func resolverCookieIsNotSentToAnotherHostAndNeverPersisted() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        let port = server.url(path: "/").port!
        var options = DownloadOptions()
        options.headers = ["Cookie": "session=orig"]
        // "localhost" and "127.0.0.1" are different hosts to mayCarryCredentials although the test server
        // answers on both; the host-header asserts below confirm the refreshed requests really used "localhost".
        options.urlResolver = {
            var request = URLRequest(url: URL(string: "http://localhost:\(port)/file.bin?sig=2")!)
            request.setValue("media=secret", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
            request.setValue("https://page.test/", forHTTPHeaderField: "Referer")
            request.setValue("tok-secret", forHTTPHeaderField: "X-Token")
            return request
        }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        try await waitUntil(timeout: .seconds(20)) { server.requests.contains { $0.path.hasSuffix("sig=2") && $0.status == 206 } }
        let destination = try #require(await job.snapshot().destination)
        let sidecar = try String(contentsOf: destination.appendingPathExtension("slpart").appendingPathExtension("json"), encoding: .utf8)
        for secret in ["media=secret", "Bearer x", "tok-secret", "session=orig", "page.test"] {
            #expect(!sidecar.contains(secret))
        }
        try await finishedOrFailed(job)
        #expect(await job.snapshot().state == .completed)
        let refreshed = server.requests.filter { $0.path.hasSuffix("sig=2") }
        #expect(!refreshed.isEmpty)
        for request in refreshed {
            #expect(request.headers["host"]?.hasPrefix("localhost") == true)
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["authorization"] == nil)
            #expect(request.headers["referer"] == "https://page.test/")
        }
    }

    @Test func aHungResolverTimesOutAndTakesTheFailurePath() async throws {
        let server = try await signedServer(testPayload(8_000_000))
        defer { server.stop() }
        var options = DownloadOptions()
        options.resolverTimeout = 1
        let calls = Counter()
        options.urlResolver = {
            _ = calls.next()
            while true { try? await Task.sleep(for: .seconds(3600)) }   // ignores cancellation on purpose
        }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        try await finishedOrFailed(job, seconds: 30)       // never stuck in .downloading
        #expect(calls.count >= 1)
        #expect(await job.snapshot().state != .downloading)
    }

    @Test func aResolverRequestWithoutAURLFailsInsteadOfStalling() async throws {
        let server = try await signedServer(testPayload(8_000_000))
        defer { server.stop() }
        var options = DownloadOptions()
        let calls = Counter()
        options.urlResolver = { _ = calls.next(); return URLRequest(url: URL(string: "http://127.0.0.1")!).withoutURL() }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        server.config.signature = "2"
        try await finishedOrFailed(job)
        #expect(calls.count >= 1)
        #expect(await job.snapshot().state != .downloading)
    }

    @Test func resolverRefreshAcceptsADifferentETagWithTheSameSize() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        var options = DownloadOptions()
        let freshURL = server.url(path: "/file.bin?sig=2")
        options.urlResolver = { URLRequest(url: freshURL) }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        var config = server.config
        config.signature = "2"
        config.etag = "\"cdn-edge-2\""                  // another edge: same bytes, other validator
        server.config = config
        try await finishedOrFailed(job)
        #expect(await job.snapshot().state == .completed)
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
    }

    @Test func aThrowingResolverWithProductiveLanesCapsAndRetriesInsteadOfFailing() async throws {
        struct ResolverFailure: Error {}
        let server = try await signedServer(testPayload(16_000_000))
        defer { server.stop() }
        var options = DownloadOptions()
        let calls = Counter()
        options.urlResolver = { _ = calls.next(); throw ResolverFailure() }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().lanes.filter { $0.segmentID != nil }.count >= 2 }
        server.config.signature = "2"
        try await waitUntil(timeout: .seconds(20)) { calls.count >= 1 }
        let state = await job.snapshot().state
        #expect(state == .downloading)                 // other lanes still receive: cap and retry, not fail
    }

    /// Starts a download, lets it make progress, pauses it, then expires the link (the old URL now answers 403).
    func pausedWithExpiredLink(_ server: TestHTTPServer, options: DownloadOptions) async throws -> DownloadJob {
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder(), options: options)
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 200_000 }
        await job.pause()
        server.config.signature = "2"
        server.config.chunkDelay = 0
        return job
    }

    @Test func startingAgainAfterTheLinkExpiredUsesTheResolver() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        var options = DownloadOptions()
        let freshURL = server.url(path: "/file.bin?sig=2")
        options.urlResolver = {
            var request = URLRequest(url: freshURL)
            request.setValue("t2", forHTTPHeaderField: "X-Token")
            return request
        }
        let job = try await pausedWithExpiredLink(server, options: options)
        await job.start()
        try await finishedOrFailed(job)
        #expect(await job.snapshot().state == .completed)
        #expect(try Data(contentsOf: #require(await job.snapshot().destination)) == payload)
        let later = server.requests.filter { $0.path.hasSuffix("sig=2") }
        #expect(!later.isEmpty)
        #expect(later.allSatisfy { $0.headers["x-token"] == "t2" })
    }

    @Test func startingAgainWithAThrowingResolverFails() async throws {
        struct ResolverFailure: Error {}
        let server = try await signedServer(testPayload(8_000_000))
        defer { server.stop() }
        var options = DownloadOptions()
        options.urlResolver = { throw ResolverFailure() }
        let job = try await pausedWithExpiredLink(server, options: options)
        await job.start()
        try await finishedOrFailed(job)
        #expect(isFailed(await job.snapshot().state))
    }

    @Test func startingAgainWithAHungResolverFails() async throws {
        let server = try await signedServer(testPayload(8_000_000))
        defer { server.stop() }
        var options = DownloadOptions()
        options.resolverTimeout = 1
        options.urlResolver = { while true { try? await Task.sleep(for: .seconds(3600)) } }
        let job = try await pausedWithExpiredLink(server, options: options)
        await job.start()
        try await finishedOrFailed(job, seconds: 15)
        #expect(isFailed(await job.snapshot().state))
    }

    @Test func startingAgainWithoutAResolverStillFailsOnAnExpiredLink() async throws {
        let server = try await signedServer(testPayload(8_000_000))
        defer { server.stop() }
        let job = try await pausedWithExpiredLink(server, options: DownloadOptions())
        await job.start()
        try await finishedOrFailed(job)
        #expect(isFailed(await job.snapshot().state))
    }

    @Test func pausingWhileTheResolverRunsCancelsItAndALaterStartResolvesAgain() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        var options = DownloadOptions()
        let calls = Counter()
        let freshURL = server.url(path: "/file.bin?sig=2")
        options.urlResolver = {
            if calls.next() == 1 { while true { try? await Task.sleep(for: .seconds(3600)) } }
            return URLRequest(url: freshURL)
        }
        let job = try await pausedWithExpiredLink(server, options: options)
        let firstStart = Task { await job.start() }     // start() waits for the hung resolver
        try await waitUntil(timeout: .seconds(10)) { calls.count >= 1 }
        await job.pause()
        await firstStart.value                          // returns at once: the cancelled resolver is abandoned
        #expect(await job.snapshot().state == .paused)   // the hung resolver did not keep the job probing
        await job.start()
        try await finishedOrFailed(job)
        #expect(await job.snapshot().state == .completed)
        #expect(calls.count == 2)
    }

    @Test func discardOnACompletedJobKeepsTheFinishedFile() async throws {
        let payload = testPayload(300_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: url), folder: tempFolder())
        await job.start()
        try await finishedOrFailed(job)
        let destination = try #require(await job.snapshot().destination)
        await job.discard()
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func discardOnAJobThatNeverStartedIsHarmless() async {
        let job = DownloadJob(request: URLRequest(url: URL(string: "http://127.0.0.1:1/x")!), folder: tempFolder())
        await job.discard()
        #expect(await job.snapshot().state == .idle)
    }

    @Test func discardStopsTheJobAndDeletesPartialFiles() async throws {
        let payload = testPayload(8_000_000)
        let server = try await signedServer(payload)
        defer { server.stop() }
        let job = DownloadJob(request: URLRequest(url: server.url(path: "/file.bin?sig=1")), folder: tempFolder())
        await job.start()
        try await waitUntil(timeout: .seconds(10)) { await job.snapshot().downloaded > 0 }
        let destination = try #require(await job.snapshot().destination)
        let partial = destination.appendingPathExtension("slpart")
        let sidecar = partial.appendingPathExtension("json")
        await job.pause()
        #expect(FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false)))
        await job.start()
        await job.discard()
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false)))
        #expect(await job.snapshot().state == .paused)
    }

    @Test func downloadJobIsADownloadTask() async throws {
        let job = DownloadJob(request: URLRequest(url: URL(string: "http://127.0.0.1:1/x")!), folder: tempFolder())
        let task: any DownloadTask = job
        #expect(task.id == job.id)
    }
}
