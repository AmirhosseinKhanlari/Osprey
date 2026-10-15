import Foundation
import Testing
@testable import OspreyMedia

@Suite struct PlaylistTitleResolverTests {
    /// `titled` entries have a real title; the rest are bare ids (like SoundCloud's set entries after the 5th).
    static func entries(_ count: Int, titled: Set<Int> = []) throws -> [PlaylistEntry] {
        try (0..<count).map { i in
            let title = titled.contains(i) ? "\"Titled \(i)\"" : "null"
            let json = "{\"id\":\"\(i)\",\"url\":\"https://api-v2.soundcloud.com/tracks/\(1000 + i)\",\"title\":\(title)}"
            return try JSONDecoder().decode(PlaylistEntry.self, from: Data(json.utf8))
        }
    }

    static func info(_ i: Int) throws -> MediaInfo {
        try infoJSON([fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)], duration: 100 + i)
    }

    /// Records each probe's start and each report, thread-safely.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [Int] = []
        private var reports: [Int: Result<MediaInfo, MediaError>] = [:]
        func start(_ i: Int) { lock.withLock { started.append(i) } }
        private var events: [PlaylistTitleResolver.Event] = []
        func report(_ i: Int, _ r: Result<MediaInfo, MediaError>) { lock.withLock { reports[i] = r } }
        func event(_ e: PlaylistTitleResolver.Event) {
            lock.withLock { events.append(e) }
            if case .finished(let i, let r) = e { report(i, r) }
        }
        var allEvents: [PlaylistTitleResolver.Event] { lock.withLock { events } }
        var order: [Int] { lock.withLock { started } }
        var results: [Int: Result<MediaInfo, MediaError>] { lock.withLock { reports } }
    }

    static func resolver(_ entries: [PlaylistEntry], limit: Int = 3, log: Log, delay: Duration = .milliseconds(5),
                         fail: Set<Int> = [], failWith: MediaError = .unavailable, debounce: Duration = .zero,
                         sleeper: TestSleeper? = nil) -> PlaylistTitleResolver {
        let sleep: @Sendable (Duration) async -> Void
        if let sleeper {
            sleep = { duration in await sleeper.sleep(duration) }
        } else {
            sleep = { duration in try? await Task.sleep(for: duration) }
        }
        return PlaylistTitleResolver(entries: entries, limit: limit, lookahead: 8, debounce: debounce, sleep: sleep,
                                     probe: { index in
            log.start(index)
            try await Task.sleep(for: delay)
            if fail.contains(index) { throw failWith }
            return try Self.info(index)
        }, report: { event in log.event(event) })
    }

    /// A clock the test moves by hand: `sleep` waits until `advance()`, and records how long it was asked to wait.
    final class TestSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var asked: [Duration] = []
        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { c in lock.withLock { asked.append(duration); waiting.append(c) } }
        }
        var requests: [Duration] { lock.withLock { asked } }
        /// The clock passes the requested pause.
        func advance() { let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { waiting = [] }; return waiting }
                         all.forEach { $0.resume() } }
    }

    @Test func wantedRowsAreTheVisibleOnesInScreenOrderThenALookaheadBelow() {
        let pending = Array(0..<444)
        func next(_ visible: [Int], done: Set<Int> = [], running: Set<Int> = []) -> Int? {
            PlaylistTitleResolver.next(pending: pending, done: done, running: running, visible: visible, lookahead: 8)
        }
        #expect(next([6, 4, 5]) == 4)
        #expect(next([4, 5, 6], done: [4], running: [5]) == 6)
        #expect(next([4, 5, 6], done: [4, 5, 6]) == 7)                         // the lookahead below
        #expect(next([4, 5, 6], done: Set(4...14)) == nil)                     // 3 visible + 8 below: then idle
        #expect(next([]) == nil)                                               // nothing on screen: nothing to read
    }

    /// 444 entries, 10 rows on screen: the 10 plus 8 below are read, and nothing else, even when left idle.
    @Test func onlyVisibleRowsAndTheLookaheadAreProbedThenIdle() async throws {
        let log = Log()
        let resolver = Self.resolver(try Self.entries(444), log: log)
        await resolver.start()
        await resolver.setVisible(Array(0..<10))
        #expect(await waitUntil { log.results.count == 18 })
        try await Task.sleep(for: .milliseconds(300))                          // the picker sits idle
        #expect(log.order.count == 18)
        #expect(Set(log.order) == Set(0..<18))
        #expect(Array(log.order.prefix(10)).sorted() == Array(0..<10))       // on-screen rows before the lookahead
        #expect(await resolver.peakRunning <= 3)
    }

    @Test func rowsThatScrollOffBeforeTheirLookupAreDropped() async throws {
        let log = Log()
        let resolver = Self.resolver(try Self.entries(444), limit: 1, log: log, delay: .milliseconds(40))
        await resolver.start()
        await resolver.setVisible(Array(0..<10))
        #expect(await waitUntil { log.order.count >= 2 })
        await resolver.setVisible(Array(200..<210))                           // scrolled far down
        #expect(await waitUntil { Set(log.results.keys).isSuperset(of: Set(200..<218)) })
        try await Task.sleep(for: .milliseconds(200))
        // At most the rows already running when the user scrolled (one, or a second that just started) finish;
        // the rest of rows 0..<18 never run. Then 200..<218, and nothing else.
        let early = log.order.filter { $0 < 200 }
        #expect(early.count <= 3 && early.allSatisfy { $0 < 18 })
        #expect(Set(log.order.filter { $0 >= 200 }) == Set(200..<218))
        #expect(log.order.count == early.count + 18)
    }

    @Test func scrollChangesAreDebounced() async throws {
        let log = Log()
        let resolver = Self.resolver(try Self.entries(444), log: log, debounce: .milliseconds(150))
        await resolver.start()
        for top in stride(from: 0, through: 200, by: 20) {                    // a fast fling past 200 rows
            await resolver.setVisible(Array(top..<(top + 10)))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitUntil { log.results.count >= 18 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(Set(log.order) == Set(200..<218))                           // only where the fling stopped
    }

    @Test func entriesWithTitlesAreNotProbed() async throws {
        let log = Log()
        let entries = try Self.entries(6, titled: [0, 2, 4])
        let resolver = Self.resolver(entries, log: log)
        #expect(resolver.pending == [1, 3, 5])
        await resolver.start()
        await resolver.setVisible(Array(0..<6))
        #expect(await waitUntil { log.results.count == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(log.order) == [1, 3, 5])
    }

    @Test func aFailureKeepsThePlaceholderAndIsNotRetried() async throws {
        let log = Log()
        let resolver = Self.resolver(try Self.entries(3), log: log, fail: [1])
        await resolver.start()
        await resolver.setVisible([0, 1, 2])
        #expect(await waitUntil { log.results.count == 3 })
        await resolver.setVisible([0, 1, 2])                                  // seen again: not retried
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.results[1] == .failure(.unavailable))
        #expect(log.order.filter { $0 == 1 }.count == 1)
        let cache = await resolver.cachedInfos()
        #expect(Set(cache.keys) == [0, 2])
    }

    // MARK: Circuit breaker

    static let forbidden = MediaError.extractionFailed("ERROR: [soundcloud] 1: Unable to download JSON metadata: HTTP Error 403: Forbidden")

    /// A 403 stops all lookups for 60 s. The row goes back to its placeholder (reset, not failed); afterwards only the
    /// rows on screen then are read.
    @Test func a403PausesLookupsUntilTheClockPassesSixtySeconds() async throws {
        let log = Log()
        let sleeper = TestSleeper()
        let resolver = Self.resolver(try Self.entries(444), limit: 1, log: log, fail: [0], failWith: Self.forbidden,
                                     sleeper: sleeper)
        await resolver.start()
        await resolver.setVisible(Array(0..<5))
        #expect(await waitUntil { sleeper.requests == [.seconds(60)] })
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.order == [0])                                            // nothing more while paused
        #expect(log.allEvents.contains(.reset(0)))
        #expect(log.results[0] == nil)                                        // not marked failed
        await resolver.setVisible(Array(100..<105))                           // a scroll during the pause
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.order == [0])                                            // doesn't restart early
        sleeper.advance()                                                     // 60 s pass
        #expect(await waitUntil { log.results.count == 5 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(Array(log.order.dropFirst()) == [100, 101, 102, 103, 104])    // only the rows visible now, no lookahead
    }

    @Test func threeFailuresInARowTripTheBreaker() async throws {
        let log = Log()
        let sleeper = TestSleeper()
        let resolver = Self.resolver(try Self.entries(444), limit: 1, log: log, fail: Set(0..<444), sleeper: sleeper)
        await resolver.start()
        await resolver.setVisible(Array(0..<10))
        #expect(await waitUntil { sleeper.requests.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.order == [0, 1, 2])
        #expect(log.results[0] == .failure(.unavailable) && log.results[1] == .failure(.unavailable))
        #expect(log.allEvents.contains(.reset(2)))                            // the third goes back to its placeholder
        await resolver.cancel()
        sleeper.advance()
    }

    /// Download reuses what the resolver already read: a cached entry needs no second lookup.
    @Test func downloadReusesTheCache() async throws {
        let log = Log()
        let resolver = Self.resolver(try Self.entries(2), log: log)
        await resolver.start()
        await resolver.setVisible([0, 1])
        #expect(await waitUntil { log.results.count == 2 })
        let cache = await resolver.cachedInfos()
        let probes = Log()
        let cached = try await PlaylistTitleResolver.info(at: 0, cache: cache) { probes.start(0); return try Self.info(0) }
        #expect(cached.duration == 100)
        #expect(probes.order.isEmpty)
        _ = try await PlaylistTitleResolver.info(at: 7, cache: cache) { probes.start(7); return try Self.info(7) }
        #expect(probes.order == [7])                                      // not cached: looked up
    }

    /// Closing the picker cancels the resolver, and its yt-dlp processes are gone.
    @Test func cancelLeavesNoProcessesBehind() async throws {
        let fake = try FakeTool(hang: true)
        defer { fake.cleanUp() }
        let extractor = MediaExtractor(tools: tools(with: fake))
        let entries = try Self.entries(5)
        let resolver = PlaylistTitleResolver(entries: entries, limit: 3, lookahead: 8, debounce: .zero,
                                             sleep: { try? await Task.sleep(for: $0) }, probe: { index in
            guard case .single(let info) = try await extractor.probe(entries[index].url, cookieHeader: nil, playlist: false)
            else { throw MediaError.unsupported }
            return info
        }, report: { _ in })
        await resolver.start()
        await resolver.setVisible(Array(0..<5))
        let path = fake.folder.path(percentEncoded: false)
        func running() -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", path]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").count
        }
        #expect(await waitUntil { running() >= 3 })
        await resolver.cancel()
        #expect(await waitUntil(timeout: 10) { running() == 0 })
    }
}
