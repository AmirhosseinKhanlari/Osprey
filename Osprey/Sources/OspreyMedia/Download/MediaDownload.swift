import Darwin
import Foundation
import OspreyEngine

// MARK: Merging

/// What MediaDownload needs from ffmpeg. `Muxer` is the real one; tests inject a fake.
public protocol MediaMerging: Sendable {
    /// `subtitleLanguage` is the subtitle's language code ("fr", "en-orig"), written as the stream's language tag.
    func mux(video: URL, audio: URL, subtitle: URL?, subtitleLanguage: String?, container: Container, to output: URL) async throws
    func convertToMP3(_ input: URL, to output: URL) async throws
}

extension Muxer: MediaMerging {}

// MARK: Parts

/// The last error a part's URL resolver threw. A DownloadJob reports a failed refresh as the HTTP error that
/// triggered it, so MediaDownload reads this to tell the user the real reason (say, the format is gone).
public final class ResolverErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: MediaError?

    public init() {}

    public var last: MediaError? { lock.withLock { _last } }

    public func record(_ error: MediaError?) { lock.withLock { _last = error } }
}

/// Builds the `DownloadTask` that fetches one part of a media plan into `file`.
public struct PartFactory: Sendable {
    public struct Context: Sendable {
        public var partID: UUID
        public var pageURL: URL
        public var part: MediaPart
        /// Where the part should end up: `<folder>/.osprey-media-<id>/video.<ext>` or `audio.<ext>`.
        public var file: URL
        public var cookieHeader: String?
        /// This part's share of the download's limit.
        public var speedLimit: Double?
        public var isPrivate: Bool
        public var tools: MediaTools
        public var extractor: MediaExtractor
        /// Where the part's URL resolver records why it failed.
        public var resolverErrors: ResolverErrorLog
        /// The part's resume sidecar when a restored download continues a direct part (nil for a new download).
        public var resume: ResumeState?

        public init(partID: UUID, pageURL: URL, part: MediaPart, file: URL, cookieHeader: String?, speedLimit: Double?,
                    isPrivate: Bool, tools: MediaTools, extractor: MediaExtractor, resolverErrors: ResolverErrorLog,
                    resume: ResumeState? = nil) {
            self.partID = partID
            self.pageURL = pageURL
            self.part = part
            self.file = file
            self.cookieHeader = cookieHeader
            self.speedLimit = speedLimit
            self.isPrivate = isPrivate
            self.tools = tools
            self.extractor = extractor
            self.resolverErrors = resolverErrors
            self.resume = resume
        }
    }

    public let make: @Sendable (Context) -> any DownloadTask

    public init(make: @escaping @Sendable (Context) -> any DownloadTask) { self.make = make }

    /// Direct formats download with the engine (headers on every request, a resolver for expired links);
    /// fragmented ones (and any without a URL) with yt-dlp.
    public static let live = PartFactory { context in
        let format = context.part.format
        guard !format.isFragmented, let url = format.url else {
            return YtDlpFragmentDownload(id: context.partID, pageURL: context.pageURL, format: format, destination: context.file,
                                         tools: context.tools, cookieHeader: context.cookieHeader, speedLimit: context.speedLimit)
        }
        var options = DownloadOptions()
        options.headers = format.httpHeaders
        options.preferredFilename = context.file.lastPathComponent
        options.isPrivate = context.isPrivate
        options.speedLimit = context.speedLimit
        options.urlResolver = urlResolver(pageURL: context.pageURL, formatID: format.formatID, cookieHeader: context.cookieHeader,
                                          extractor: context.extractor, errors: context.resolverErrors)
        if let resume = context.resume {
            // A restored part continues from its sidecar; an expired URL is refreshed by the resolver above.
            return DownloadJob(id: context.partID, resuming: resume, options: options)
        }
        return DownloadJob(id: context.partID, request: URLRequest(url: url), folder: context.file.deletingLastPathComponent(),
                           options: options)
    }

    /// Re-extracts the page and returns the same format's fresh URL and headers.
    /// Throws `MediaError.formatsChanged` when that format is gone or no longer a direct download.
    static func urlResolver(pageURL: URL, formatID: String, cookieHeader: String?, extractor: MediaExtractor,
                            errors: ResolverErrorLog) -> @Sendable () async throws -> URLRequest {
        {
            do {
                let result = try await extractor.probe(pageURL, cookieHeader: cookieHeader, playlist: false)
                guard case .single(let info) = result,
                      let fresh = info.formats.first(where: { $0.formatID == formatID }),
                      !fresh.isFragmented, let url = fresh.url else { throw MediaError.formatsChanged }
                var request = URLRequest(url: url)
                for (field, value) in fresh.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
                errors.record(nil)
                return request
            } catch let error as MediaError {
                errors.record(error)
                throw error
            }
        }
    }
}

// MARK: Snapshots

public struct MediaPartStatus: Sendable, Equatable {
    public var role: MediaPart.Role
    public var state: DownloadState
    public var downloaded: Int64
    public var total: Int64?
    /// The part's own last snapshot (its segments and lanes), for drawing its share of the progress bar.
    public var detail: DownloadSnapshot? = nil
}

public struct MediaSnapshot: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle, downloading, merging, completed, paused
        case failed(MediaError)
    }

    public var phase: Phase
    public var parts: [MediaPartStatus]
    public var finalFile: URL?
    /// Set when the download finished but something was left out (subtitles); nil otherwise.
    public var warning: MediaWarning? = nil
}

/// Why subtitles were left out of a finished video.
public enum SubtitleProblem: Sendable, Equatable, Codable {
    /// The site answered an HTTP error (YouTube answers 429 to direct auto-translated captions).
    case refused(site: String, status: Int)
    /// No answer, or not a web address.
    case unreachable
    /// The answer wasn't a subtitle file or playlist that could be read.
    case unreadable
    /// ffmpeg couldn't put the subtitles into the file.
    case notEmbedded
}

/// Something a finished download left out. A subtitle problem never fails the download: the video and audio are
/// saved without them.
public enum MediaWarning: Sendable, Equatable, Codable {
    case subtitlesSkipped(SubtitleProblem)

    public var userMessage: String {
        switch self {
        case .subtitlesSkipped(let problem):
            let cause = switch problem {
            case .refused(let site, _): "\(site) refused the captions"
            case .unreachable: "the captions couldn't be downloaded"
            case .unreadable: "the captions couldn't be read"
            case .notEmbedded: "the captions couldn't be embedded"
            }
            return "Saved without subtitles (\(cause))"
        }
    }

    /// "YouTube" for YouTube addresses, else the host without "www.".
    public static func siteName(for url: URL) -> String {
        let host = (url.host(percentEncoded: false) ?? "").lowercased()
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") { return "YouTube" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : (host.isEmpty ? "The site" : host)
    }
}

/// Why one subtitle track couldn't be fetched; turned into a `SubtitleProblem` for the warning.
private enum SubtitleFetchFailure: Error {
    case refused(Int), unreachable, unreadable
}

// MARK: Orchestrator

/// Downloads a plan's 1–2 parts into a hidden folder, then merges or converts them with ffmpeg (or just moves a
/// single part) into `<folder>/<title> [<id>].<ext>`. Part completion is noticed by polling the parts.
public actor MediaDownload: DownloadTask {
    public nonisolated let id: UUID
    public nonisolated let pageURL: URL
    public nonisolated let info: MediaInfo
    public nonisolated let plan: MediaPlan

    private struct Slot {
        let part: MediaPart
        let task: any DownloadTask
        let file: URL
        let errors: ResolverErrorLog
        var last: DownloadSnapshot?

        var isCompleted: Bool { last?.state == .completed }
    }

    private enum MergeKind { case move, mux, mp3 }

    /// The folder the final file goes to.
    public nonisolated let folder: URL
    /// The `<uuid>` of the hidden part folder: the download's id, or for a restored download the saved one.
    public nonisolated let hiddenFolderID: UUID
    private let hiddenFolder: URL
    private let merger: any MediaMerging
    private let pollInterval: Duration
    private let mergeKind: MergeKind
    /// `<sanitized title>.<ext>`, shown until the final file exists.
    private let displayName: String
    /// `<sanitized title> [<id>].<ext>`, made unique when the merge starts.
    private let finalName: String

    private var slots: [Slot]
    private var phase: MediaSnapshot.Phase = .idle
    private var speedLimit: Double?
    private var finalFile: URL?
    /// What the last merge left out (subtitles), shown with the finished item.
    private var warning: MediaWarning?
    /// Bumped by start, pause, discard and a part failure, so an older await can tell it has been superseded.
    private var generation = 0
    private var discarded = false
    private var poller: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?

    public init(id: UUID = UUID(), pageURL: URL, info: MediaInfo, plan: MediaPlan, folder: URL, cookieHeader: String?,
                speedLimit: Double?, isPrivate: Bool, tools: MediaTools, extractor: MediaExtractor, partFactory: PartFactory = .live,
                merger: (any MediaMerging)? = nil, pollInterval: Duration = .milliseconds(250)) {
        self.init(id: id, hiddenFolderID: id, restoring: nil, pageURL: pageURL, info: info, plan: plan, folder: folder,
                  cookieHeader: cookieHeader, speedLimit: speedLimit, isPrivate: isPrivate, tools: tools, extractor: extractor,
                  partFactory: partFactory, merger: merger, pollInterval: pollInterval)
    }

    /// Rebuilds a download from the saved list, paused, with the same id and hidden folder:
    /// - A part whose file is there, with no work file beside it, is done.
    /// - A direct part resumes from its sidecar; a fragmented one through yt-dlp's `--continue`.
    /// - With every part done (`readyToMerge`), `start()` goes straight to the merge.
    /// - With `failure` (it failed before the app quit), it shows that message until `start()` resumes it.
    public init(resuming record: MediaRecord, id: UUID, pageURL: URL, cookieHeader: String?, speedLimit: Double?,
                tools: MediaTools, extractor: MediaExtractor, partFactory: PartFactory = .live,
                merger: (any MediaMerging)? = nil, pollInterval: Duration = .milliseconds(250), failure: String? = nil) {
        self.init(id: id, hiddenFolderID: record.hiddenFolderID, restoring: record, pageURL: pageURL,
                  info: record.video.mediaInfo, plan: record.plan, folder: record.folder, cookieHeader: cookieHeader,
                  speedLimit: speedLimit, isPrivate: false, tools: tools, extractor: extractor, partFactory: partFactory,
                  merger: merger, pollInterval: pollInterval, failure: failure)
    }

    private init(id: UUID, hiddenFolderID: UUID, restoring record: MediaRecord?, pageURL: URL, info: MediaInfo,
                 plan: MediaPlan, folder: URL, cookieHeader: String?, speedLimit: Double?, isPrivate: Bool,
                 tools: MediaTools, extractor: MediaExtractor, partFactory: PartFactory,
                 merger: (any MediaMerging)?, pollInterval: Duration, failure: String? = nil) {
        self.id = id
        self.hiddenFolderID = hiddenFolderID
        self.pageURL = pageURL
        self.info = info
        self.plan = plan
        self.folder = folder
        let hidden = folder.appending(path: ".osprey-media-\(hiddenFolderID.uuidString)", directoryHint: .isDirectory)
        self.hiddenFolder = hidden
        self.merger = merger ?? Muxer(tools: tools)
        self.pollInterval = pollInterval
        self.speedLimit = speedLimit

        let kind: MergeKind
        if plan.convertToMP3 {
            kind = .mp3
        } else if plan.parts.count > 1 {
            kind = .mux
        } else if plan.subtitle != nil, plan.parts.first?.format.hasAudio == true {
            kind = .mux             // one file with both streams: it is passed as video and as audio
        } else {
            kind = .move            // a subtitle can't be muxed without an audio stream to map; it is dropped
        }
        mergeKind = kind
        let ext = kind == .move ? Self.cleanExtension(plan.parts.first?.format.ext ?? plan.container.fileExtension)
                                : plan.container.fileExtension
        let title = Self.cleanComponent(info.title)
        displayName = ContentDisposition.sanitize("\(title).\(ext)")
        finalName = Self.mediaFileName(title: info.title, id: info.id, ext: ext)
        if let record {
            phase = failure.map { .failed(.downloadFailed($0)) } ?? .paused
            warning = record.warning
        }

        let share = speedLimit.map { $0 / Double(max(1, plan.parts.count)) }
        let restoring = record != nil
        slots = plan.parts.map { part in
            let stem = part.role == .audio ? "audio" : "video"
            let file = hidden.appending(path: ContentDisposition.sanitize("\(stem).\(Self.cleanExtension(part.format.ext))"))
            let errors = ResolverErrorLog()
            let partID = UUID()
            if restoring, Self.isFinishedPart(file) {
                let done = Self.finishedPartSnapshot(file)
                return Slot(part: part, task: ArchivedTask(id: partID, snapshot: done), file: file, errors: errors, last: done)
            }
            let resume = restoring ? (try? ResumeStore.load(from: Self.sidecar(for: file))) : nil
            let context = PartFactory.Context(partID: partID, pageURL: pageURL, part: part, file: file, cookieHeader: cookieHeader,
                                              speedLimit: share, isPrivate: isPrivate, tools: tools, extractor: extractor,
                                              resolverErrors: errors, resume: resume)
            return Slot(part: part, task: partFactory.make(context), file: file, errors: errors,
                        last: restoring ? Self.pausedPartSnapshot(file, resume: resume) : nil)
        }
    }

    // MARK: DownloadTask

    /// Starts (or resumes) the unfinished parts. When every part is already done (a merge failed), it retries only the merge.
    public func start() async {
        guard !discarded else { return }
        switch phase {
        case .idle, .paused, .failed: break
        default: return
        }
        generation += 1
        let gen = generation
        guard !slots.isEmpty else {
            phase = .failed(.extractionFailed("nothing to download"))
            return
        }
        if slots.allSatisfy(\.isCompleted) {
            phase = .merging
            launchMerge(gen)
            return
        }
        do {
            try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
        } catch {
            phase = .failed(.downloadFailed(error.localizedDescription))
            return
        }
        for slot in slots { slot.errors.record(nil) }
        phase = .downloading
        let pending = slots.filter { !$0.isCompleted }.map(\.task)
        let share = currentShare()
        await withTaskGroup(of: Void.self) { group in
            for task in pending {
                group.addTask {
                    await task.setSpeedLimit(share)
                    await task.start()
                }
            }
        }
        // A pause or discard ran while the parts were starting; one of them may have started after it.
        guard gen == generation else { await reconcile(); return }
        startPoller(gen)
    }

    /// Pauses every part. Ignored while merging (ffmpeg can't be paused; an interrupted merge reruns from the parts).
    public func pause() async {
        guard !discarded, phase == .downloading else { return }
        phase = .paused
        generation += 1
        let gen = generation
        poller?.cancel()
        poller = nil
        await pauseParts()
        guard gen == generation else { return }
        await refreshSnapshots()
    }

    /// Quitting: pauses the parts, or stops a running merge (ffmpeg is stopped, and its partial output removed) so the
    /// download is saved `readyToMerge` and the next launch merges again from the finished parts.
    public func suspendForQuit() async {
        guard !discarded else { return }
        switch phase {
        case .downloading:
            await pause()
        case .merging:
            generation += 1                          // the merge sees it was superseded and leaves the state alone
            let running = mergeTask
            mergeTask = nil
            running?.cancel()                        // ProcessRunner stops ffmpeg's group; Muxer removes its partial file
            phase = .paused
            await running?.value
        default:
            break
        }
    }

    public func setSpeedLimit(_ bytesPerSecond: Double?) {
        speedLimit = bytesPerSecond
        Task { await self.pushSpeedLimits() }
    }

    public func snapshot() -> DownloadSnapshot {
        var downloaded: Int64 = 0
        var total: Int64? = 0
        var speed: Double = 0
        var segments: [Segment] = []
        var lanes: [LaneSnapshot] = []
        var offset: Int64? = 0                       // earlier parts' total size; unknown once any is unknown
        // Part sizes can come from the site (yt-dlp's estimates): sums that don't fit become unknown, never a trap.
        for slot in slots {
            guard let part = slot.last else { total = nil; offset = nil; continue }
            downloaded = MediaText.saturatingSum(downloaded, part.downloaded)
            total = total.flatMap { sum in part.totalSize.flatMap { MediaText.sum(sum, $0) } }
            speed += part.bytesPerSecond
            var shift = offset ?? 0
            if let last = part.segments.map(\.end).max(), MediaText.sum(last, shift) == nil { shift = 0 }
            var segmentIDs: [Int: Int] = [:]
            for segment in part.segments {
                let newID = segments.count
                segmentIDs[segment.id] = newID
                segments.append(Segment(id: newID, start: segment.start + shift, end: segment.end + shift, received: segment.received))
            }
            for lane in part.lanes {
                lanes.append(LaneSnapshot(id: lanes.count, segmentID: lane.segmentID.flatMap { segmentIDs[$0] },
                                          phase: lane.phase, bytesPerSecond: lane.bytesPerSecond))
            }
            offset = offset.flatMap { sum in part.totalSize.flatMap { MediaText.sum(sum, $0) } }
        }
        let running = phase == .downloading
        let state: DownloadState = switch phase {
        case .idle: .idle
        case .downloading: .downloading
        case .merging: .finishing
        case .completed: .completed
        case .paused: .paused
        case .failed(let error): .failed(error.userMessage)
        }
        let acceptsRanges = !slots.isEmpty && slots.allSatisfy { $0.last?.acceptsRanges == true }
        return DownloadSnapshot(state: state, fileName: finalFile?.lastPathComponent ?? displayName, totalSize: total,
                                downloaded: downloaded, bytesPerSecond: running ? speed : 0, segments: segments,
                                lanes: running ? lanes : [], acceptsRanges: acceptsRanges, etag: nil, destination: finalFile)
    }

    /// Discards the parts and deletes the hidden folder. A finished file is kept. The download never starts again.
    public func discard() async {
        discarded = true
        generation += 1
        poller?.cancel()
        poller = nil
        mergeTask?.cancel()                          // ffmpeg is killed; the merge sees it was superseded
        mergeTask = nil
        if phase != .completed { phase = .idle }
        await discardParts()
    }

    // MARK: Media

    public func mediaSnapshot() -> MediaSnapshot {
        MediaSnapshot(phase: phase,
                      parts: slots.map { MediaPartStatus(role: $0.part.role, state: $0.last?.state ?? .idle,
                                                         downloaded: $0.last?.downloaded ?? 0, total: $0.last?.totalSize,
                                                         detail: $0.last) },
                      finalFile: finalFile, warning: warning)
    }

    // MARK: Restoring

    /// What the saved list keeps for this download (`phase` comes from the app's last `mediaSnapshot()`).
    public nonisolated func record(phase: MediaRecord.Phase, warning: MediaWarning?) -> MediaRecord {
        MediaRecord(video: MediaRecord.Video(info), plan: plan, folder: folder, hiddenFolderID: hiddenFolderID,
                    phase: phase, warning: warning)
    }

    /// A part a restored download already finished: its file is there and no engine or yt-dlp work file is beside it.
    static func isFinishedPart(_ file: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path(percentEncoded: false)) else { return false }
        let name = file.lastPathComponent
        let siblings = (try? fm.contentsOfDirectory(atPath: file.deletingLastPathComponent().path(percentEncoded: false))) ?? []
        return !siblings.contains { $0.hasPrefix(name + ".part") || $0 == name + ".ytdl" || $0 == name + ".slpart" }
    }

    /// `<file>.slpart.json`, the engine's resume sidecar for a direct part.
    static func sidecar(for file: URL) -> URL {
        file.appendingPathExtension("slpart").appendingPathExtension("json")
    }

    static func finishedPartSnapshot(_ file: URL) -> DownloadSnapshot {
        let size = fileSize(file)
        return DownloadSnapshot(state: .completed, fileName: file.lastPathComponent, totalSize: size, downloaded: size,
                                bytesPerSecond: 0, segments: [], lanes: [], acceptsRanges: true, etag: nil, destination: file)
    }

    /// A restored unfinished part before it runs: the sidecar's progress for a direct part, or the size of yt-dlp's
    /// `<name>.part*` files for a fragmented one.
    static func pausedPartSnapshot(_ file: URL, resume: ResumeState?) -> DownloadSnapshot {
        if let resume {
            return DownloadSnapshot(state: .paused, fileName: file.lastPathComponent, totalSize: resume.totalSize,
                                    downloaded: resume.map.downloaded, bytesPerSecond: 0, segments: resume.map.segments,
                                    lanes: [], acceptsRanges: resume.acceptsRanges, etag: resume.etag,
                                    destination: resume.destination, lastModified: resume.lastModified)
        }
        let folder = file.deletingLastPathComponent()
        let name = file.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let partial = names.filter { $0.hasPrefix(name + ".part") }.reduce(Int64(0)) { $0 + fileSize(folder.appending(path: $1)) }
        return DownloadSnapshot(state: .paused, fileName: name, totalSize: nil, downloaded: partial, bytesPerSecond: 0,
                                segments: [], lanes: [], acceptsRanges: false, etag: nil, destination: nil)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Parts

    private func refreshSnapshots() async {
        for index in slots.indices {
            let snapshot = await slots[index].task.snapshot()
            slots[index].last = snapshot
        }
    }

    private func currentShare() -> Double? {
        let running = slots.filter { !$0.isCompleted }.count
        return speedLimit.map { $0 / Double(max(1, running)) }
    }

    /// Gives each unfinished part an even share of the limit. The share is recomputed before every call, so
    /// overlapping pushes (two quick limit changes) still end on the latest value.
    private func pushSpeedLimits() async {
        for index in slots.indices where !slots[index].isCompleted {
            await slots[index].task.setSpeedLimit(currentShare())
        }
    }

    private func pauseParts() async {
        let tasks = slots.filter { !$0.isCompleted }.map(\.task)
        await withTaskGroup(of: Void.self) { group in
            for task in tasks { group.addTask { await task.pause() } }
        }
    }

    private func discardParts() async {
        let tasks = slots.map(\.task)
        await withTaskGroup(of: Void.self) { group in
            for task in tasks { group.addTask { await task.discard() } }
        }
        try? FileManager.default.removeItem(at: hiddenFolder)
    }

    /// Re-applies the current intent after a superseded start: a part may have started after a pause or discard.
    private func reconcile() async {
        if discarded {
            await discardParts()
            return
        }
        switch phase {
        case .paused, .failed: await pauseParts()
        default: break                               // a newer start owns the parts
        }
    }

    private func startPoller(_ gen: Int) {
        poller?.cancel()
        let interval = pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let keepGoing = await self?.tick(gen), keepGoing else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One poll: refreshes the part snapshots, then fails, re-splits the limit, or starts the merge. False ends polling.
    private func tick(_ gen: Int) async -> Bool {
        guard gen == generation, phase == .downloading else { return false }
        let finishedBefore = slots.filter(\.isCompleted).count
        await refreshSnapshots()
        guard gen == generation, phase == .downloading else { return false }

        if let failed = slots.first(where: { if case .failed = $0.last?.state { true } else { false } }),
           case .failed(let message)? = failed.last?.state {
            await failPart(failed, message: message)
            return false
        }
        if slots.allSatisfy(\.isCompleted) {
            poller = nil
            phase = .merging
            launchMerge(gen)
            return false
        }
        // A part found paused or idle while the download runs (a pause that landed after a newer start) is started again.
        let stalled = slots.filter { $0.last?.state == .paused || $0.last?.state == .idle }.map(\.task)
        if !stalled.isEmpty {
            let share = currentShare()
            for task in stalled {
                await task.setSpeedLimit(share)
                await task.start()
            }
            // A pause or discard during those starts: re-apply it to the part that was just started.
            guard gen == generation, phase == .downloading else { await reconcile(); return false }
        }
        if slots.filter(\.isCompleted).count != finishedBefore {
            await pushSpeedLimits()
            guard gen == generation, phase == .downloading else { return false }
        }
        return true
    }

    private func failPart(_ slot: Slot, message: String) async {
        let known: [MediaError] = [.unsupported, .drmProtected, .loginRequired, .unavailable, .timedOut, .formatsChanged]
        let error = slot.errors.last ?? known.first { $0.userMessage == message } ?? .downloadFailed(message)
        phase = .failed(error)
        generation += 1
        let gen = generation
        poller = nil
        await pauseParts()
        guard gen == generation else { return }
        await refreshSnapshots()
    }

    // MARK: Merge

    private func launchMerge(_ gen: Int) {
        mergeTask = Task { await self.merge(gen) }
    }

    private func merge(_ gen: Int) async {
        guard gen == generation, phase == .merging else { return }
        let fm = FileManager.default
        let inputs = slots.map { $0.last?.destination ?? $0.file }
        var output: URL?
        warning = nil
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            switch mergeKind {
            case .move:
                output = try Self.moveWithoutReplacing(inputs[0], into: folder, name: finalName)
                // A subtitle needs an audio stream to map alongside; a video-only file is saved without it.
                if plan.subtitle != nil { warning = .subtitlesSkipped(.notEmbedded) }
            case .mp3, .mux:
                // The final name is reserved (its `.partial` file created exclusively) before ffmpeg runs, so a second
                // merge of the same video picks the next name instead of overwriting this one.
                let reserved = try Self.reserveName(in: folder, name: finalName)
                output = reserved
                defer { Self.dropPlaceholder(for: reserved) }
                if mergeKind == .mp3 {
                    let audio = slots.firstIndex { $0.part.role == .audio } ?? 0
                    try await merger.convertToMP3(inputs[audio], to: reserved)
                } else {
                    // A subtitle problem never costs the download: fetching (every track, HLS included) or
                    // embedding failing saves the video and audio alone, with a warning naming the cause.
                    var subtitle: URL?
                    if let track = plan.subtitle {
                        do {
                            subtitle = try await downloadSubtitle(track, alternates: plan.subtitleAlternates)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            warning = .subtitlesSkipped(Self.problem(error as? SubtitleFetchFailure ?? .unreachable,
                                                                     pageURL: pageURL))
                        }
                        guard gen == generation else { return }
                    }
                    let video = slots.firstIndex { $0.part.role != .audio } ?? 0
                    let audio = slots.firstIndex { $0.part.role == .audio } ?? video
                    do {
                        try await merger.mux(video: inputs[video], audio: inputs[audio], subtitle: subtitle,
                                             subtitleLanguage: subtitle == nil ? nil : plan.subtitleLanguage,
                                             container: plan.container, to: reserved)
                    } catch where subtitle != nil && !(error is CancellationError) {
                        guard gen == generation, !discarded else { return }
                        // The failed run removed the reservation; take the name again and merge without subtitles.
                        let retry = try Self.reserveName(in: folder, name: finalName)
                        output = retry
                        defer { Self.dropPlaceholder(for: retry) }
                        try await merger.mux(video: inputs[video], audio: inputs[audio], subtitle: nil, subtitleLanguage: nil,
                                             container: plan.container, to: retry)
                        warning = .subtitlesSkipped(.notEmbedded)
                    }
                }
            }
        } catch {
            guard gen == generation, !discarded else { return }
            mergeTask = nil
            phase = .failed(error as? MediaError ?? .muxFailed(error.localizedDescription))
            return
        }
        guard let output else { return }
        guard gen == generation, !discarded else {
            try? fm.removeItem(at: output)
            return
        }
        DownloadJob.quarantine(output, data: pageURL, origin: pageURL)
        try? fm.removeItem(at: hiddenFolder)
        mergeTask = nil
        finalFile = output
        phase = .completed
    }

    private static func problem(_ failure: SubtitleFetchFailure, pageURL: URL) -> SubtitleProblem {
        switch failure {
        case .refused(let status): .refused(site: MediaWarning.siteName(for: pageURL), status: status)
        case .unreachable: .unreachable
        case .unreadable: .unreadable
        }
    }

    /// The first of `track` and `alternates` that downloads, as a local file; the first failure is thrown when none
    /// does. YouTube answers 429 for direct auto-translated captions, and its HLS track (an alternate) still works.
    private func downloadSubtitle(_ track: SubtitleTrack, alternates: [SubtitleTrack]) async throws -> URL {
        var firstError: (any Error)?
        for candidate in [track] + alternates {
            do {
                return candidate.isHLS ? try await downloadHLSSubtitle(candidate) : try await downloadSubtitle(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? SubtitleFetchFailure.unreachable
    }

    private func downloadSubtitle(_ track: SubtitleTrack) async throws -> URL {
        let target = hiddenFolder.appending(path: ContentDisposition.sanitize("subtitle.\(Self.cleanExtension(track.ext))"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let temp = try await Self.fetch(track.url, session: session)
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.moveItem(at: temp, to: target) } catch { throw SubtitleFetchFailure.unreadable }
        return target
    }

    /// An HLS subtitle track: the playlist, then each WebVTT segment in order, joined into one `.vtt` file.
    private func downloadHLSSubtitle(_ track: SubtitleTrack) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let playlist = try await Self.fetchText(track.url, session: session)
        let urls: [URL]
        do {
            urls = try HLSSubtitles.segments(in: playlist, playlistURL: track.url)
        } catch {
            throw SubtitleFetchFailure.unreadable
        }
        var segments: [String] = []
        for url in urls {
            try Task.checkCancellation()
            segments.append(try await Self.fetchText(url, session: session))
        }
        let target = hiddenFolder.appending(path: "subtitle.vtt")
        try? FileManager.default.removeItem(at: target)
        do {
            try Data(HLSSubtitles.join(segments).utf8).write(to: target)
        } catch {
            throw SubtitleFetchFailure.unreadable
        }
        return target
    }

    /// Downloads `url` (http(s) only: a site's subtitle URL must never make Osprey read a local file into the
    /// video) to a temporary file the caller removes.
    private static func fetch(_ url: URL, session: URLSession) async throws -> URL {
        guard MediaURL.isWebURL(url) else { throw SubtitleFetchFailure.unreachable }
        let temp: URL, response: URLResponse
        do {
            (temp, response) = try await session.download(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SubtitleFetchFailure.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw SubtitleFetchFailure.refused(http.statusCode)
        }
        return temp
    }

    /// A playlist or segment as UTF-8 text, refused past `HLSSubtitles.maxBytes`.
    private static func fetchText(_ url: URL, session: URLSession) async throws -> String {
        let temp = try await fetch(url, session: session)
        defer { try? FileManager.default.removeItem(at: temp) }
        let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= HLSSubtitles.maxBytes, let data = try? Data(contentsOf: temp),
              let text = String(data: data, encoding: .utf8) else {
            throw SubtitleFetchFailure.unreadable
        }
        return text
    }

    // MARK: Naming

    /// Room kept free in a 255-byte file name: `.osprey-partial` (19) and a " NNNNN" next-name suffix (6).
    static let nameReserve = ".osprey-partial".utf8.count + 6

    /// `<title> [<id>].<ext>`, sanitized, with the title shortened (on a character boundary) so that the name, its
    /// `.osprey-partial` file and a uniquing " 2" all fit in 255 bytes. The id and the extension are always kept.
    static func mediaFileName(title: String, id: String, ext: String) -> String {
        let idPart = " [\(prefix(cleanComponent(id), bytes: 60))]"
        let extPart = ".\(ext)"
        let budget = min(255 - nameReserve, ContentDisposition.maxNameBytes) - idPart.utf8.count - extPart.utf8.count
        let shortTitle = prefix(cleanComponent(title), bytes: max(1, budget))
        return ContentDisposition.sanitize("\(shortTitle)\(idPart)\(extPart)")
    }

    private static func prefix(_ text: String, bytes limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Picks the first free `name` (`name 2`, …) and creates its `.partial` file exclusively, so no other merge can take it.
    static func reserveName(in folder: URL, name: String) throws -> URL {
        let ext = (name as NSString).pathExtension
        for _ in 0..<10_000 {
            let candidate = FileNaming.uniqueURL(in: folder, name: name)
            let placeholder = Muxer.partialURL(for: candidate, fallbackExtension: ext)
            let fd = open(placeholder.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                // Marked as Osprey's own, so only it can be swept after a crash.
                do { try MediaCleanup.markAsPartial(placeholder) } catch {
                    try? FileManager.default.removeItem(at: placeholder)
                    throw error
                }
                // A final file may have appeared between the check and the reservation.
                if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                    try? FileManager.default.removeItem(at: placeholder)
                    continue
                }
                return candidate
            }
            guard errno == EEXIST else { throw MediaError.muxFailed("couldn't create the output file") }
        }
        throw MediaError.muxFailed("couldn't choose a file name")
    }

    /// Removes the reservation if the merger left it empty (it failed, or a merger that doesn't use the partial file ran).
    static func dropPlaceholder(for output: URL) {
        let placeholder = Muxer.partialURL(for: output, fallbackExtension: output.pathExtension)
        let path = placeholder.path(percentEncoded: false)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size == 0 {
            try? FileManager.default.removeItem(at: placeholder)
        }
    }

    /// Moves `source` to the first free `name` in `folder`, atomically and never over an existing file.
    static func moveWithoutReplacing(_ source: URL, into folder: URL, name: String) throws -> URL {
        for _ in 0..<10_000 {
            let candidate = FileNaming.uniqueURL(in: folder, name: name)
            if renamex_np(source.path(percentEncoded: false), candidate.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            guard errno == EEXIST else { throw MediaError.muxFailed(String(cString: strerror(errno))) }
        }
        throw MediaError.muxFailed("couldn't choose a file name")
    }

    /// A title or id as one file-name component: path separators become dashes (sanitize would keep only the last piece).
    private static func cleanComponent(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
    }

    private static func cleanExtension(_ ext: String) -> String {
        let cleaned = ext.filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "bin" : String(cleaned.prefix(10))
    }
}
