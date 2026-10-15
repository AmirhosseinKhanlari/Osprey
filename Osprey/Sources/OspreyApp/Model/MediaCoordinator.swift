import AppKit
import Foundation
import Observation
import OspreyEngine
import OspreyIntegration
import OspreyMedia

/// Drives the video picker: takes a page (from Add URL or a browser's video button), makes sure yt-dlp is
/// there, looks the page up, and turns the user's choice into media downloads.
@MainActor @Observable
final class MediaCoordinator {
    /// The page the picker is showing.
    struct Request: Equatable {
        let id = UUID()
        var pageURL: URL
        var cookieHeader: String?
        var isPrivate: Bool
        /// The browser tab's title, shown while the lookup runs.
        var title: String?
        var origin: DownloadOrigin
    }

    enum State: Equatable {
        case idle
        /// Installing yt-dlp; the fraction downloaded when known.
        case settingUpTools(Double?)
        case loading
        case single(MediaInfo)
        case playlist(PlaylistInfo)
        case error(MediaError)
    }

    private(set) var request: Request?
    private(set) var state: State = .idle
    /// The picker sheet should be up. The main window presents it (see ContentView).
    private(set) var isPresented = false
    /// Whether ffmpeg was found the last time we looked (on open and after an install).
    private(set) var hasFFmpeg = false
    /// Installing ffmpeg from the picker's "Install" link; the fraction when known.
    private(set) var ffmpegProgress: Double??
    private(set) var ffmpegError: String?
    /// Playlists whose entries are being looked up and added after the picker closed, by batch. They run
    /// independently of the picker; only Stop cancels them.
    private(set) var batches: [UUID: PlaylistBatchProgress] = [:]
    /// What the title resolver read for the open playlist's untitled entries, by row.
    private(set) var resolvedEntries: [Int: ResolvedEntry] = [:]
    /// Rows whose lookup is running (they show a small spinner).
    private(set) var resolvingRows: Set<Int> = []

    /// The open playlist is music: from an audio site, or its first entry has no video. Its quality then defaults to
    /// Audio · M4A (and Save to to the Music folder).
    private(set) var playlistPrefersAudio = false
    let settings: MediaSettings

    /// The batches in the order they started, for the banner.
    var batchList: [PlaylistBatchProgress] { batchOrder.compactMap { batches[$0] } }

    @ObservationIgnored private let manager: DownloadManager
    @ObservationIgnored private let installer: ToolInstaller
    @ObservationIgnored private let mediaLookup: MediaLookup
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var batchTasks: [UUID: Task<Void, Never>] = [:]
    /// Reads untitled entries' real titles while the playlist picker is open; cancelled with it.
    @ObservationIgnored private var titleResolver: PlaylistTitleResolver?
    /// Visible-row updates for the resolver, delivered in the order they happened (a stale set never wins).
    @ObservationIgnored private var visibleRowsFeed: AsyncStream<[Int]>.Continuation?
    /// The tasks that forward visible rows to the resolver and its events back here, in order.
    @ObservationIgnored private var titleTasks: [Task<Void, Never>] = []
    /// The open playlist's first-entry lookup (is it music?); cancelled when the picker closes or is replaced.
    @ObservationIgnored private var audioCheck: Task<Void, Never>?
    /// The request the picker is for, so a closing sheet can tell whether it's still current.
    @ObservationIgnored private var shown = PickerRequestTracker()
    /// One limit for every playlist batch: at most two yt-dlp lookups at a time in total.
    @ObservationIgnored private let probeSlots = AsyncLimiter(limit: 2)
    @ObservationIgnored private var batchOrder: [UUID] = []
    /// The request whose safety-net install has returned: later install progress for it is stale.
    @ObservationIgnored private var installFinished: UUID?
    /// Opens (or brings forward) the main window; installed by the app delegate.
    @ObservationIgnored var showMainWindow: (@MainActor () -> Void)?

    private var tools: MediaTools { manager.mediaTools }

    init(manager: DownloadManager, settings: MediaSettings) {
        self.manager = manager
        self.settings = settings
        installer = ToolInstaller(tools: manager.mediaTools)
        mediaLookup = MediaLookup(tools: manager.mediaTools, installer: installer, extractor: MediaExtractor(tools: manager.mediaTools))
    }

    // MARK: Opening

    /// A browser's "Download video" request. Brings Osprey forward: the user asked for the picker.
    func open(_ order: MediaOrder) {
        present(Request(pageURL: order.pageURL, cookieHeader: order.cookieHeader, isPrivate: order.isPrivate,
                        title: order.title, origin: .browser(fromMenu: order.source == .menu)))
    }

    /// A page typed into Add URL.
    func open(url: URL) {
        present(Request(pageURL: url, cookieHeader: nil, isPrivate: false, title: nil, origin: .addURL))
    }

    private func present(_ new: Request) {
        stopTitleResolver()
        audioCheck?.cancel()                          // the first-entry check belongs to the request being replaced
        audioCheck = nil
        request = new
        playlistPrefersAudio = false
        shown.open(new.id)
        isPresented = true
        ffmpegError = nil
        refreshFFmpeg()
        // Open the main window first when it's closed, so the sheet has somewhere to go.
        showMainWindow?()
        Self.bringForward()
        retry()
    }

    /// The user asked for the picker from a browser, so Osprey comes forward (the one exception to not
    /// taking focus). Cooperative activation refuses `activate()` while the browser is active; opening our own
    /// bundle through Launch Services, as a user's open would, is honoured.
    private static func bringForward() {
        NSApp.activate()
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        DispatchQueue.main.async {
            guard !NSApp.isActive else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
        }
    }

    /// Runs (or reruns) the tool check and the lookup for the current request.
    func retry() {
        lookup?.cancel()
        guard let request else { return }
        lookup = Task { [weak self] in await self?.lookUp(request) }
    }

    /// Closes the picker and drops the lookup.
    func close() {
        lookup?.cancel()
        lookup = nil
        stopTitleResolver()
        audioCheck?.cancel()
        audioCheck = nil
        request = nil
        shown.close()
        state = .idle
        isPresented = false
    }

    /// The picker sheet finished closing for request `id`. Closes only if that request is still the current one: a
    /// browser click that arrived while the old sheet animated out has already been told "taken" and must stay.
    func close(ifCurrent id: UUID?) {
        guard shown.current != nil, shown.current == id else { return }
        close()
    }

    // MARK: Lookup

    private func lookUp(_ request: Request) async {
        guard await ensureTools(for: request) else { return }
        state = .loading
        do {
            // Flat unless the URL names one video in a list; `_type` in the answer picks the playlist or single pane.
            let result = try await probe(request)
            guard isCurrent(request) else { return }
            switch result {
            case .single(let info):
                if FormatCatalog.isFullyProtected(info) {
                    state = .error(.drmProtected)
                } else if FormatCatalog.videoOptions(for: info, compatible: false).isEmpty, FormatCatalog.audioOptions(for: info).isEmpty {
                    state = .error(.unsupported)          // nothing downloadable (say, only storyboards)
                } else {
                    state = .single(info)
                }
            case .playlist(let list):
                state = list.entries.isEmpty ? .error(.unsupported) : .playlist(list)
                checkPlaylistIsAudio(list, request: request)
                startTitleResolver(list, request: request)
            }
        } catch {
            guard isCurrent(request) else { return }
            state = .error(Self.mediaError(error))
        }
    }

    // MARK: Playlist titles

    /// Looks up the untitled entries the user can see (and 8 rows below), three at a time; nothing else. Each answer
    /// updates `resolvedEntries`; what it reads is reused when the playlist is downloaded.
    private func startTitleResolver(_ list: PlaylistInfo, request: Request) {
        let lookup = mediaLookup
        let entries = list.entries
        let (eventStream, events) = AsyncStream.makeStream(of: PlaylistTitleResolver.Event.self)
        let resolver = PlaylistTitleResolver(entries: entries, limit: 3, lookahead: 8, probe: { index in
            let entry = entries[index]
            // The browser's cookies are for the playlist page's site; an entry elsewhere gets none.
            let cookies = MediaURL.cookieHeader(request.cookieHeader, from: request.pageURL, for: entry.url)
            guard case .single(let info) = try await lookup.probe(entry.url, cookieHeader: cookies, playlist: false,
                                                                  progress: { _ in }) else { throw MediaError.unsupported }
            return info
        }, report: { event in
            events.yield(event)                        // one stream: events arrive here in the order they happened
        })
        guard !resolver.pending.isEmpty else {
            events.finish()
            return
        }
        titleResolver = resolver
        let (rowsStream, rowsFeed) = AsyncStream.makeStream(of: [Int].self, bufferingPolicy: .bufferingNewest(1))
        visibleRowsFeed = rowsFeed
        titleTasks = [
            Task { [weak self] in
                for await event in eventStream { self?.titleEvent(event, request: request.id) }
            },
            Task {
                await resolver.start()
                for await rows in rowsStream { await resolver.setVisible(rows) }
            },
        ]
    }

    private func titleEvent(_ event: PlaylistTitleResolver.Event, request id: UUID) {
        guard request?.id == id else { return }
        let index: Int, result: Result<MediaInfo, MediaError>
        switch event {
        case .started(let row):
            if resolvedEntries[row] == nil { resolvingRows.insert(row) }   // never a spinner on a finished row
            return
        case .reset(let row):
            resolvingRows.remove(row)                 // the circuit breaker gave up on it for now: placeholder again
            return
        case .finished(let row, let outcome):
            index = row
            result = outcome
        }
        resolvingRows.remove(index)
        switch result {
        case .success(let info):
            resolvedEntries[index] = .title(info.title, duration: info.duration)
        case .failure(.drmProtected):
            resolvedEntries[index] = .protected
        case .failure:
            resolvedEntries[index] = .failed
        }
    }

    /// The checklist's rows on screen: the resolver reads them next.
    func setVisibleRows(_ rows: Set<Int>) {
        visibleRowsFeed?.yield(rows.sorted())         // forwarded in order; only the newest waiting set is kept
    }

    private func stopTitleResolver() {
        if let resolver = titleResolver { Task { await resolver.cancel() } }
        titleResolver = nil
        visibleRowsFeed?.finish()
        visibleRowsFeed = nil
        titleTasks.forEach { $0.cancel() }
        titleTasks = []
        resolvedEntries = [:]
        resolvingRows = []
    }

    /// An audio site's playlist is music at once; otherwise the first entry is looked up (one quick probe) and the
    /// playlist counts as music when that entry has no video.
    private func checkPlaylistIsAudio(_ list: PlaylistInfo, request: Request) {
        switch MediaURL.siteKind(request.pageURL) {
        case .audio:
            playlistPrefersAudio = true
            return
        case .video:
            return                                    // a video site's playlist is videos: no extra lookup
        case .unknown:
            break
        }
        guard let first = list.entries.first else { return }
        let lookup = mediaLookup
        let cookie = MediaURL.cookieHeader(request.cookieHeader, from: request.pageURL, for: first.url)
        audioCheck?.cancel()
        audioCheck = Task { [weak self] in
            guard case .single(let info)? = try? await lookup.probe(first.url, cookieHeader: cookie, playlist: false,
                                                                    progress: { _ in }) else { return }
            guard let self, self.request?.id == request.id else { return }
            if FormatCatalog.videoOptions(for: info, compatible: false).isEmpty, !FormatCatalog.audioOptions(for: info).isEmpty {
                self.playlistPrefersAudio = true
            }
        }
    }

    /// Probes with the safety net: a stale Homebrew yt-dlp that can't read the page triggers the managed install
    /// (shown as "Setting up…") and one retry.
    private func probe(_ request: Request) async throws -> MediaProbeResult {
        try await mediaLookup.probe(request.pageURL, cookieHeader: request.cookieHeader) { event in
            Task { @MainActor in
                // Late hops must not overwrite a result, an error, or the retry that already started.
                guard self.request?.id == request.id else { return }
                switch self.state {
                case .settingUpTools, .loading: break
                default: return
                }
                switch event {
                case .installing(let fraction):
                    guard self.installFinished != request.id else { return }
                    self.state = .settingUpTools(fraction)
                case .extracting:
                    self.installFinished = request.id
                    self.state = .loading
                }
            }
        }
    }

    /// Makes sure Osprey's own yt-dlp is there, installing it on first use with progress. A Homebrew copy is
    /// used only when that install fails. False when the picker moved on or no yt-dlp is available at all.
    private func ensureTools(for request: Request) async -> Bool {
        guard mediaLookup.needsSetup else { return true }
        state = .settingUpTools(nil)
        do {
            // Holds the coordinator only until the install ends.
            try await mediaLookup.prepare { fraction in
                Task { @MainActor in
                    guard self.request?.id == request.id, case .settingUpTools = self.state else { return }
                    self.state = .settingUpTools(fraction)
                }
            }
            return isCurrent(request)
        } catch {
            guard isCurrent(request) else { return false }
            state = .error(Self.mediaError(error))
            return false
        }
    }

    private func isCurrent(_ request: Request) -> Bool { !Task.isCancelled && self.request?.id == request.id }

    private static func mediaError(_ error: any Error) -> MediaError {
        if let media = error as? MediaError { return media }
        if error is CancellationError { return .timedOut }
        return .extractionFailed(error.localizedDescription)
    }

    // MARK: ffmpeg

    func refreshFFmpeg() { hasFFmpeg = tools.locate(.ffmpeg) != nil }

    /// The picker's "Needs ffmpeg — Install" link.
    func installFFmpeg() {
        guard ffmpegProgress == nil else { return }
        ffmpegProgress = .some(nil)
        ffmpegError = nil
        Task { [installer] in
            do {
                _ = try await installer.install(.ffmpeg, from: .ffmpeg(arch: .current)) { fraction in
                    Task { @MainActor in
                        if self.ffmpegProgress != nil { self.ffmpegProgress = .some(fraction) }
                    }
                }
            } catch {
                ffmpegError = Self.mediaError(error).userMessage
            }
            ffmpegProgress = nil
            refreshFFmpeg()
        }
    }

    // MARK: Downloads

    /// Adds the single video in the chosen quality and closes the picker. `audioLanguage` is what the picker's language
    /// menu chose (remembered for next time); nil when the video has one audio language.
    /// `subtitle` is the picker's Subtitles choice (an uploaded track, or an automatic caption when `isAuto`); it is
    /// embedded only when this video still offers it.
    func download(option: QualityOption, subtitle: SubtitleChoice?, audioLanguage: String?, folder: URL) {
        guard case .single(let info) = state, let request else { return }
        var plan = option.plan
        let hasVideo = plan.parts.contains { $0.role != .audio }
        let menu = SubtitleMenu(info: info, chosen: subtitle)
        let chosen = hasVideo ? menu.resolve(subtitle) : nil
        if let chosen {
            let tracks = menu.tracks(for: chosen, in: info)
            if let track = tracks.first {
                plan.subtitle = track
                plan.subtitleAlternates = Array(tracks.dropFirst())
                plan.subtitleLanguage = chosen.language
            }
        }
        if hasVideo, let height = plan.parts.first(where: { $0.role != .audio })?.format.height { settings.maxHeight = height }
        if hasVideo {
            settings.subtitleLanguage = chosen?.language
            settings.subtitleIsAuto = chosen?.isAuto ?? false
        }
        if let audioLanguage, audioLanguage != settings.audioLanguage { settings.audioLanguage = audioLanguage }
        manager.addMedia(pageURL: request.pageURL, info: info, plan: plan, folder: folder, cookieHeader: request.cookieHeader,
                         isPrivate: request.isPrivate, playlistTitle: nil, startNow: true, origin: request.origin)
        close()
    }

    /// Closes the picker, then looks up each chosen entry (two at a time) and adds it, in playlist order,
    /// into `<folder>/<playlist title>/`. Each entry's plan is decided when it's added (protection, ffmpeg).
    /// `audioFolder`: where entries that turn out to be audio only (a video cap on, say, SoundCloud) go; nil when
    /// the user chose the folder in the sheet, so everything goes there.
    /// `audioLanguage`: the language each entry's audio should be in; an entry without it gets its original track.
    /// `rows`: the chosen entries' positions in the playlist; an entry the title resolver already read is not looked
    /// up again.
    func downloadPlaylist(rows: [Int], cap: QualityCap, compatible: Bool, audioLanguage: String, folder: URL,
                          audioFolder: URL?) {
        guard case .playlist(let list) = state, let request, !rows.isEmpty else { return }
        let entries = rows.map { list.entries[$0] }
        let resolver = titleResolver                  // close() cancels it; what it read is still there
        let title = list.title
        let target = folder.appending(path: Self.folderName(title), directoryHint: .isDirectory)
        let audioTarget = (audioFolder ?? folder).appending(path: Self.folderName(title), directoryHint: .isDirectory)
        close()
        refreshFFmpeg()
        let batchID = UUID()
        // Wording: an audio format makes tracks, a video cap videos.
        let kind: MediaKind = cap == .audioM4A || cap == .audioMP3 ? .audio : .video
        batches[batchID] = PlaylistBatchProgress(playlistTitle: request.isPrivate ? nil : title, done: 0, total: entries.count,
                                                 kind: kind)
        batchOrder.append(batchID)
        let lookup = mediaLookup
        let slots = probeSlots
        let hasFFmpeg = self.hasFFmpeg
        settings.audioLanguage = audioLanguage
        batchTasks[batchID] = Task { [weak self] in
            let cache = await resolver?.cachedInfos() ?? [:]
            var results: [Int: Result<MediaInfo, MediaError>] = [:]
            var next = 0
            var failures: [PlaylistFailure] = []
            await withTaskGroup(of: (Int, Result<MediaInfo, MediaError>).self) { group in
                var launched = 0
                func launch() {
                    guard launched < entries.count, !Task.isCancelled else { return }
                    let index = launched
                    let entry = entries[index]
                    // The browser's cookies are for the playlist page's site; an entry elsewhere gets none.
                    let cookies = MediaURL.cookieHeader(request.cookieHeader, from: request.pageURL, for: entry.url)
                    launched += 1
                    if let cached = cache[rows[index]] {
                        group.addTask { (index, .success(cached)) }      // read while the picker was open
                        return
                    }
                    group.addTask {
                        await slots.withSlot {
                            guard !Task.isCancelled else { return (index, .failure(.timedOut)) }
                            do {
                                switch try await lookup.probe(entry.url, cookieHeader: cookies, playlist: false, progress: { _ in }) {
                                case .single(let info): return (index, .success(info))
                                case .playlist: return (index, .failure(.unsupported))
                                }
                            } catch let error as MediaError {
                                return (index, .failure(error))
                            } catch {
                                return (index, .failure(.extractionFailed(error.localizedDescription)))
                            }
                        }
                    }
                }
                launch()
                launch()
                for await (index, result) in group {
                    results[index] = result
                    launch()
                    // Add in playlist order: everything ready from the front of the list.
                    while !Task.isCancelled, let ready = results[next] {
                        results[next] = nil
                        let entry = entries[next]
                        next += 1
                        guard let self else { continue }
                        switch ready.mapError({ PlaylistFailure.Reason($0) }).flatMap({ info in
                            FormatCatalog.playlistPlan(for: info, cap: cap, compatible: compatible, hasFFmpeg: hasFFmpeg,
                                                          audioLanguage: audioLanguage)
                                .map { (info, $0) }.mapError { PlaylistFailure.Reason($0) }
                        }) {
                        case .success(let (info, plan)):
                            let audioOnly = !plan.parts.contains { $0.role != .audio }
                            self.manager.addMedia(pageURL: entry.url, info: info, plan: plan, folder: audioOnly ? audioTarget : target,
                                                  cookieHeader: MediaURL.cookieHeader(request.cookieHeader, from: request.pageURL,
                                                                                      for: entry.url),
                                                  isPrivate: request.isPrivate,
                                                  playlistTitle: title, startNow: true, origin: request.origin)
                        case .failure(let reason):
                            // The real title when the lookup returned one, else the entry's own or "Track N";
                            // never a name guessed from the link.
                            let known = (try? ready.get())?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            failures.append(PlaylistFailure(title: known.flatMap { $0.isEmpty ? nil : $0 }
                                                                ?? entry.knownTitle(at: rows[next - 1]), reason: reason))
                        }
                        self.batches[batchID]?.done = next
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.endBatch(batchID)
            if !failures.isEmpty {
                NSLog("Osprey: %d playlist entries weren't added (%d protected)", failures.count,
                      failures.filter { $0.reason == .protected }.count)
                CaptureNotifier.notifyPlaylistFailures(playlist: title, failures: failures, isPrivate: request.isPrivate, kind: kind)
            }
        }
    }

    /// The banner's Stop: stops adding every playlist's remaining entries. Entries already added stay.
    func cancelPlaylistBatches() {
        for task in batchTasks.values { task.cancel() }
        batchTasks = [:]
        batches = [:]
        batchOrder = []
    }

    private func endBatch(_ id: UUID) {
        batchTasks[id] = nil
        batches[id] = nil
        batchOrder.removeAll { $0 == id }
    }

    /// A playlist title made safe as one folder name.
    static func folderName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let short = String(cleaned.prefix(120))
        return short.isEmpty ? "Playlist" : short
    }
}

/// What the title resolver found for one playlist row.
enum ResolvedEntry: Equatable {
    case title(String, duration: Double?)
    /// The lookup said DRM: the row shows a lock.
    case protected
    /// The lookup failed: the row keeps its placeholder with "couldn't read".
    case failed
}
