import Foundation
import OspreyEngine

/// Downloads one fragmented (HLS/DASH) format by running yt-dlp and streaming its progress lines.
/// yt-dlp starts helpers (ffmpeg), so every stop signals the whole process group.
public actor YtDlpFragmentDownload: DownloadTask {
    public nonisolated let id: UUID

    private let pageURL: URL
    private let format: MediaFormat
    private let destination: URL
    private let tools: MediaTools
    private let cookieHeader: String?
    /// Applied at the next launch (yt-dlp can't change `--limit-rate` while running).
    private var speedLimit: Double?

    private var state: DownloadState = .idle
    private var progress: ProgressLine?
    private var child: ChildProcess?
    private var monitor: Task<Void, Never>?
    private var cookieJar: CookieJarFile?
    private var generation = 0
    private let pauseGrace: TimeInterval

    public init(id: UUID, pageURL: URL, format: MediaFormat, destination: URL, tools: MediaTools,
                cookieHeader: String?, speedLimit: Double?, pauseGrace: TimeInterval = 5) {
        self.pauseGrace = pauseGrace
        self.id = id
        self.pageURL = pageURL
        self.format = format
        self.destination = destination
        self.tools = tools
        self.cookieHeader = cookieHeader
        self.speedLimit = speedLimit
    }

    // MARK: DownloadTask

    public func start() async {
        // A start during an in-flight pause waits for the old process to finish, then relaunches.
        if child != nil, state == .paused { await monitor?.value }
        guard child == nil, state != .completed, state != .downloading else { return }
        guard MediaURL.isWebURL(pageURL) else { state = .failed(MediaError.unsupported.userMessage); return }
        guard let ytdlp = tools.locate(.ytdlp) else { state = .failed(MediaError.toolMissing("yt-dlp").userMessage); return }

        // `%` starts a template field in yt-dlp's -o, so a literal one is doubled.
        let outputTemplate = destination.path(percentEncoded: false).replacingOccurrences(of: "%", with: "%%")
        var args = ["--ignore-config", "-f", format.formatID, "--concurrent-fragments", "8", "--newline", "--continue", "--no-warnings", "--no-playlist",
                    "--progress-template",
                    "download:SLIPPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s %(progress.fragment_index)s %(progress.fragment_count)s",
                    "-o", outputTemplate]
        if let limit = speedLimit, limit.isFinite, limit >= 1 { args += ["--limit-rate", String(Int64(min(limit, 1e15)))] }
        // A Finder-launched app has a bare PATH; without this yt-dlp can't find ffmpeg and leaves HLS as MPEG-TS.
        if let ffmpeg = tools.locate(.ffmpeg) { args += ["--ffmpeg-location", ffmpeg.url.path(percentEncoded: false)] }
        var jar: CookieJarFile?
        if let header = cookieHeader, !header.isEmpty {
            do {
                let file = try CookieJarFile.write(cookieHeader: header, for: pageURL)
                jar = file
                args += ["--cookies", file.url.path(percentEncoded: false)]
            } catch {
                state = .failed((error as? MediaError)?.userMessage ?? MediaError.extractionFailed("couldn't prepare cookies").userMessage)
                return
            }
        }
        args += ["--", pageURL.absoluteString]      // `--`: the page URL is never read as an option

        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(executable: ytdlp.url, arguments: args,
                                             environment: ProcessRunner.sanitizedEnvironment(ProcessInfo.processInfo.environment))
        } catch {
            jar?.delete()
            state = .failed(MediaError.toolMissing("yt-dlp").userMessage)
            return
        }
        generation += 1
        let gen = generation
        child = process
        cookieJar = jar
        state = .downloading

        let (lines, continuation) = AsyncStream<String>.makeStream()
        let splitter = LineSplitter(continuation)
        let out = PipeReader(fd: process.stdoutFD, onData: { splitter.feed($0) }, onEnd: { splitter.finish() })
        let err = PipeReader(fd: process.stderrFD, keep: 64 * 1024)
        monitor = Task { [self] in
            let consumer = Task { [self] in
                for await line in lines { apply(line, generation: gen) }
            }
            let status = await process.waitForExit()
            // Give a lingering helper that still holds the pipes 2 s, then kill whatever is left in the group.
            _ = await out.finished(timeout: 2)
            process.signalGroup(SIGKILL)
            MediaCleanup.shared.unregister(process)        // the group is down
            _ = await out.finished(timeout: 1)
            _ = await err.finished(timeout: 1)
            out.stop(); err.stop()
            await consumer.value
            ended(generation: gen, status: status, stderr: String(decoding: err.collected(), as: UTF8.self))
        }
    }

    /// SIGINT to the group (yt-dlp keeps its `.part` state), SIGKILL after 5 s, then wait for the exit.
    public func pause() async {
        guard let process = child, state == .downloading else { return }
        // Already exited (say, non-zero) and only waiting to be processed: let the real result stand.
        guard process.isRunning else { await monitor?.value; return }
        state = .paused
        await stop(process, interrupt: true)
    }

    public func setSpeedLimit(_ bytesPerSecond: Double?) { speedLimit = bytesPerSecond }

    public func snapshot() -> DownloadSnapshot {
        let downloaded = progress?.downloaded ?? 0
        let total = progress?.total.map { max($0, downloaded) }
        let speed = state == .downloading ? (progress?.speed ?? 0) : 0
        var lanes: [LaneSnapshot] = []
        if state == .downloading {
            // One synthetic lane per fragment worker that has work left (yt-dlp runs up to 8), or a single lane.
            var workers = 1
            if let (index, count) = progress?.fragment { workers = min(8, max(1, count - index + 1)) }
            lanes = (0..<workers).map { LaneSnapshot(id: $0, segmentID: nil, phase: .receiving, bytesPerSecond: speed / Double(workers)) }
        }
        var segments: [Segment] = []
        if let total, total > 0 { segments = [Segment(id: 0, start: 0, end: total - 1, received: min(downloaded, total))] }
        return DownloadSnapshot(state: state, fileName: destination.lastPathComponent, totalSize: total, downloaded: downloaded,
                                bytesPerSecond: speed, segments: segments, lanes: lanes, acceptsRanges: false, etag: nil,
                                destination: destination)
    }

    /// Stops the process tree and deletes `destination`, `destination.part*` and the `.ytdl` state file.
    public func discard() async {
        if let process = child {
            state = .idle
            await stop(process, interrupt: false)
        }
        state = .idle
        progress = nil
        cookieJar?.delete(); cookieJar = nil
        let fm = FileManager.default
        let name = destination.lastPathComponent
        let folder = destination.deletingLastPathComponent()
        try? fm.removeItem(at: destination)
        // yt-dlp's fixup leftover: `<name>.temp.<ext>`.
        let temp = destination.deletingPathExtension().appendingPathExtension("temp").appendingPathExtension(destination.pathExtension)
        try? fm.removeItem(at: temp)
        for item in (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        where item.hasPrefix(name + ".part") || item == name + ".ytdl" {
            try? fm.removeItem(at: folder.appending(path: item))
        }
    }

    // MARK: Internals

    private func stop(_ process: ChildProcess, interrupt: Bool) async {
        if interrupt {
            process.signalGroup(SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + pauseGrace) { if process.isRunning { process.signalGroup(SIGKILL) } }
        } else {
            process.signalGroup(SIGKILL)
        }
        _ = await process.waitForExit()
        await monitor?.value
    }

    private func apply(_ line: String, generation gen: Int) {
        guard gen == generation, state == .downloading, let parsed = ProgressLine.parse(line) else { return }
        progress = parsed
    }

    private func ended(generation gen: Int, status: Int32, stderr: String) {
        guard gen == generation else { return }
        child = nil
        monitor = nil
        cookieJar?.delete(); cookieJar = nil
        // Paused or discarded: the exit (often 130) was requested, not a result.
        if state == .paused || state == .idle {
            if status == 0, state == .paused { complete() }
            return
        }
        if status == 0 { complete() } else { state = .failed(MediaExtractor.map(stderr: Self.lastErrorBlock(stderr)).userMessage) }
    }

    /// The last `ERROR:` line (earlier ones are often retries); the whole text when there is none.
    private static func lastErrorBlock(_ stderr: String) -> String {
        stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR:") }.map(String.init) ?? stderr
    }

    private func complete() {
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? nil
        guard let size, size > 0 else {
            state = .failed(MediaError.extractionFailed("yt-dlp produced no file").userMessage)
            return
        }
        let bytes = max(progress?.downloaded ?? 0, size)
        progress = ProgressLine(downloaded: bytes, total: bytes, speed: nil, fragment: nil)
        state = .completed
    }
}

/// Turns raw pipe chunks into complete lines.
private final class LineSplitter: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var pending = Data()

    init(_ continuation: AsyncStream<String>.Continuation) { self.continuation = continuation }

    func feed(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var result: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                result.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                pending = Data(pending[(newline + 1)...])
            }
            return result
        }
        lines.forEach { continuation.yield($0) }
    }

    func finish() {
        let rest = lock.withLock { () -> String? in
            defer { pending = Data() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let rest { continuation.yield(rest) }
        continuation.finish()
    }
}
