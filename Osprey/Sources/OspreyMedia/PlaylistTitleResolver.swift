import Foundation

/// Reads the real title (and duration) of playlist entries that came without one, such as SoundCloud set entries
/// after the fifth, which are bare track ids. Strictly lazy: only the rows on screen and a few rows below them
/// (`lookahead`) are read, in screen order, at most `limit` at a time. A row that scrolls away before its lookup
/// starts is dropped; once the wanted rows are done the resolver sits idle. (Reading a whole 444-track set makes
/// SoundCloud answer 403 for a while, which also breaks the downloads.) Scroll changes are debounced, so a fast
/// fling queues only where it stops. What it reads is kept, so a download needs no second lookup. Lives as long as
/// one picker request: `cancel()` stops every lookup (their yt-dlp processes are killed).
///
/// Circuit breaker: an HTTP 403 or 429 (the site is limiting us), or three failures in a row, pauses every lookup for
/// `pause` (60 s). The rows it gave up on go back to their placeholders (`.reset`, not failed). When the pause ends,
/// only the rows on screen at that moment are read (no lookahead until the next scroll); a scroll during the pause
/// doesn't restart anything early.
public actor PlaylistTitleResolver {
    public typealias Probe = @Sendable (Int) async throws -> MediaInfo

    public enum Event: Sendable, Equatable {
        /// A lookup for this row started (the row shows a spinner).
        case started(Int)
        case finished(Int, Result<MediaInfo, MediaError>)
        /// The lookup was abandoned by the circuit breaker: the row shows its placeholder again (not failed).
        case reset(Int)
    }

    public typealias Report = @Sendable (Event) -> Void

    /// Indices of the entries that need a lookup: those without a title of their own.
    public nonisolated let pending: [Int]

    private let pendingSet: Set<Int>
    private let limit: Int
    private let lookahead: Int
    private let debounce: Duration
    private let pause: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let probe: Probe
    private let report: Report
    private var visible: [Int] = []
    private var running: Set<Int> = []
    private var done: Set<Int> = []
    private var cache: [Int: MediaInfo] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var debounceTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var paused = false
    private var failuresInARow = 0
    /// After a pause, only the rows on screen are read until the user scrolls again.
    private var lookaheadOverride: Int?
    private var started = false
    private var cancelled = false
    /// The most lookups seen running at once (for tests).
    public private(set) var peakRunning = 0

    public init(entries: [PlaylistEntry], limit: Int = 3, lookahead: Int = 8, debounce: Duration = .milliseconds(150),
                pause: Duration = .seconds(60),
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                probe: @escaping Probe, report: @escaping Report) {
        pending = entries.indices.filter { Self.needsLookup(entries[$0]) }
        pendingSet = Set(pending)
        self.limit = max(1, limit)
        self.lookahead = max(0, lookahead)
        self.debounce = debounce
        self.pause = pause
        self.sleep = sleep
        self.probe = probe
        self.report = report
    }

    /// An entry without a title of its own. Titled entries (YouTube's flat playlists) are never looked up.
    public static func needsLookup(_ entry: PlaylistEntry) -> Bool {
        (entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    public func start() {
        guard !started, !cancelled else { return }
        started = true
        fill()
    }

    /// The rows on screen now. Applied after the debounce: the visible rows are read first, then `lookahead` rows
    /// below them; queued rows that are no longer wanted are dropped.
    public func setVisible(_ rows: [Int]) {
        debounceTask?.cancel()
        let sorted = rows.sorted()
        guard debounce > .zero else {
            apply(sorted)
            return
        }
        let wait = debounce
        debounceTask = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self.apply(sorted)
        }
    }

    public func cancel() {
        cancelled = true
        debounceTask?.cancel()
        pauseTask?.cancel()
        for task in tasks.values { task.cancel() }
        tasks = [:]
        running = []
    }

    /// Every entry read so far, by index.
    public func cachedInfos() -> [Int: MediaInfo] { cache }

    /// The next row to read: the top visible one not read yet; else the first of the `lookahead` rows below the
    /// visible ones; else nil (idle).
    static func next(pending: [Int], done: Set<Int>, running: Set<Int>, visible: [Int], lookahead: Int) -> Int? {
        guard let bottom = visible.max() else { return nil }
        let pendingSet = Set(pending)
        let wanted = visible.sorted() + Array((bottom + 1)..<(bottom + 1 + lookahead))
        return wanted.first { pendingSet.contains($0) && !done.contains($0) && !running.contains($0) }
    }

    /// The site is limiting us: HTTP 403 or 429 in yt-dlp's error.
    public static func isRateLimit(_ error: MediaError) -> Bool {
        guard case .extractionFailed(let detail) = error else { return false }
        return ["HTTP Error 403", "HTTP Error 429", "Too Many Requests"].contains { detail.localizedCaseInsensitiveContains($0) }
    }

    /// For the download: the entry's cached info, else a lookup.
    public static func info(at index: Int, cache: [Int: MediaInfo],
                            probe: () async throws -> MediaInfo) async throws -> MediaInfo {
        if let cached = cache[index] { return cached }
        return try await probe()
    }

    // MARK: Work

    private func apply(_ rows: [Int]) {
        visible = rows
        guard !paused else { return }                 // read when the pause ends, from where the user is then
        lookaheadOverride = nil
        if started { fill() }
    }

    private func fill() {
        while !cancelled, !paused, running.count < limit,
              let index = Self.next(pending: pending, done: done, running: running, visible: visible,
                                    lookahead: lookaheadOverride ?? lookahead) {
            running.insert(index)
            peakRunning = max(peakRunning, running.count)
            report(.started(index))
            let probe = self.probe
            tasks[index] = Task {
                let result: Result<MediaInfo, MediaError>
                do {
                    result = .success(try await probe(index))
                } catch let error as MediaError {
                    result = .failure(error)
                } catch {
                    result = .failure(.extractionFailed(error.localizedDescription))
                }
                self.finish(index, result)          // the task runs on this actor
            }
        }
    }

    private func finish(_ index: Int, _ result: Result<MediaInfo, MediaError>) {
        guard !cancelled else { return }
        running.remove(index)
        tasks[index] = nil
        switch result {
        case .success(let info):
            failuresInARow = 0
            done.insert(index)
            cache[index] = info
            report(.finished(index, result))
        case .failure(let error):
            failuresInARow += 1
            if paused || Self.isRateLimit(error) || failuresInARow >= 3 {
                report(.reset(index))                 // not this row's fault: try it again later
                trip()
            } else {
                done.insert(index)
                report(.finished(index, result))
            }
        }
        fill()
    }

    /// Stops all lookups for `pause`; then reads the rows on screen at that moment.
    private func trip() {
        guard !paused else { return }
        paused = true
        failuresInARow = 0
        let sleep = self.sleep, pause = self.pause
        pauseTask = Task {
            await sleep(pause)
            guard !Task.isCancelled else { return }
            self.resume()
        }
    }

    private func resume() {
        guard !cancelled, paused else { return }
        paused = false
        lookaheadOverride = 0
        fill()
    }
}
