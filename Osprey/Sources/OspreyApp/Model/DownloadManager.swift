import Foundation
import Observation
import OspreyEngine
import OspreyIntegration
import OspreyLibrary
import OspreyMedia

@MainActor @Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []
    var maxConcurrent = 4
    var speedLimitMBps: Double? { didSet { applySpeedLimit() } }
    private(set) var throughputHistory: [Double] = Array(repeating: 0, count: 120)
    private(set) var totalSpeed: Double = 0
    private(set) var activeConnections = 0
    /// The download the main window should select next time it shows (set by a progress window's "Show all").
    var focusRequest: DownloadItem.ID?
    let rootFolder: URL
    /// Where yt-dlp and ffmpeg are found for media downloads.
    let mediaTools: MediaTools
    /// The saved list (`library.json`), the Keychain items holding sign-in cookies, and the rules joining them
    /// (see DownloadManager+Library.swift).
    let library: DownloadLibrary
    let vault: any CredentialStoring
    let recorder: LibraryRecorder
    /// The queues (`queues.json`), Main first. Changed only by DownloadManager+Queues.swift, which saves them.
    let queueStore: QueueStore
    var queues: [Queue]
    /// Hidden part folders of the unfinished videos `restore()` brought back; the launch sweep keeps them.
    @ObservationIgnored var restoredHiddenFolderIDs: Set<UUID> = []
    /// The state each item was last saved with, so a change is saved (and flushed) once.
    @ObservationIgnored var savedStates: [UUID: DownloadState] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastRefresh = ContinuousClock.now
    /// Set while quitting: the queue starts nothing more.
    @ObservationIgnored private var queueStopped = false

    init(rootFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
         mediaTools: MediaTools = MediaTools(), library: DownloadLibrary = DownloadLibrary(),
         vault: any CredentialStoring = CredentialVault(), queueStore: QueueStore = QueueStore()) {
        self.rootFolder = rootFolder
        self.mediaTools = mediaTools
        self.library = library
        self.vault = vault
        recorder = LibraryRecorder(library: library, vault: vault)
        self.queueStore = queueStore
        queues = queueStore.load()
    }

    var activeCount: Int { items.filter { $0.status == .downloading }.count }

    /// Bytes still to fetch across running downloads whose size is known.
    var remainingBytes: Int64 { items.filter { $0.status == .downloading }.compactMap(\.remaining).reduce(0, +) }

    /// The speed limit in bytes per second, or nil.
    var currentSpeedLimit: Double? { speedLimitMBps.map { $0 * 1_000_000 } }

    func items(for filter: SidebarFilter, search: String) -> [DownloadItem] {
        items.filter { item in
            filter.matches(item) && (search.isEmpty
                || item.snapshot.fileName.localizedCaseInsensitiveContains(search)
                || item.host.localizedCaseInsensitiveContains(search))
        }
    }

    func count(for filter: SidebarFilter) -> Int { items.filter { filter.matches($0) }.count }

    // MARK: Adding

    @discardableResult
    func add(_ url: URL, connections: Int, category: Category?, startNow: Bool, origin: DownloadOrigin = .addURL,
             headers: [String: String] = [:], preferredFilename: String? = nil, isPrivate: Bool = false) -> DownloadItem {
        let category = category ?? Category.infer(fromFileName: Self.inferenceName(preferredFilename) ?? url.lastPathComponent)
        let item = makeFileItem(url: url, folder: rootFolder.appending(path: category.rawValue), category: category,
                                connections: connections, origin: origin, headers: headers,
                                preferredFilename: preferredFilename, isPrivate: isPrivate, startNow: startNow)
        insert(item, at: 0, credentials: headers)
        return item
    }

    /// A download handed over by a browser extension: starts at once with the browser's headers.
    /// The caller (CaptureService) decides how to tell the user: progress window or notification.
    @discardableResult
    func addCaptured(_ order: CaptureOrder) -> DownloadItem {
        let saved = UserDefaults.standard.integer(forKey: "maxConnections")
        return add(order.url, connections: saved > 0 ? saved : 8, category: nil, startNow: true,
                   origin: .browser(fromMenu: order.source == .menu),
                   headers: order.headers, preferredFilename: order.preferredFilename, isPrivate: order.isPrivate)
    }

    /// A video (or its audio) picked in the media picker: its 1–2 parts download, then merge into `folder`.
    /// It takes one queue slot like any download.
    @discardableResult
    func addMedia(pageURL: URL, info: MediaInfo, plan: MediaPlan, folder: URL, cookieHeader: String?, isPrivate: Bool,
                  playlistTitle: String?, startNow: Bool, origin: DownloadOrigin = .addURL) -> DownloadItem {
        let item = makeMediaItem(pageURL: pageURL, info: info, plan: plan, folder: folder, cookieHeader: cookieHeader,
                                 isPrivate: isPrivate, playlistTitle: playlistTitle, startNow: startNow, origin: origin)
        insert(item, at: 0, credentials: cookieHeader.map { ["Cookie": $0] } ?? [:])
        return item
    }

    /// A new file download, not yet listed or saved.
    func makeFileItem(id: UUID = UUID(), url: URL, folder: URL, category: Category, connections: Int, origin: DownloadOrigin,
                      headers: [String: String], preferredFilename: String?, isPrivate: Bool, startNow: Bool) -> DownloadItem {
        var options = DownloadOptions()
        options.maxConnections = connections
        options.speedLimit = currentSpeedLimit
        options.headers = headers
        options.preferredFilename = preferredFilename
        options.isPrivate = isPrivate
        let job = DownloadJob(id: id, request: URLRequest(url: url), folder: folder, options: options)
        return DownloadItem(task: job, url: url, category: category, origin: origin, maxConnections: connections,
                            wantsToRun: startNow, folder: folder, isPrivate: isPrivate, preferredFilename: preferredFilename,
                            requestHeaders: headers)
    }

    /// A new video download, not yet listed or saved.
    func makeMediaItem(pageURL: URL, info: MediaInfo, plan: MediaPlan, folder: URL, cookieHeader: String?, isPrivate: Bool,
                       playlistTitle: String?, startNow: Bool, origin: DownloadOrigin) -> DownloadItem {
        let task = MediaDownload(pageURL: pageURL, info: info, plan: plan, folder: folder, cookieHeader: cookieHeader,
                                 speedLimit: currentSpeedLimit, isPrivate: isPrivate, tools: mediaTools,
                                 extractor: MediaExtractor(tools: mediaTools))
        let audioOnly = plan.parts.allSatisfy { $0.role == .audio }
        // Each direct part opens up to the engine's default connections.
        let connections = DownloadOptions().maxConnections * max(1, plan.parts.count)
        return DownloadItem(task: task, url: pageURL, category: audioOnly ? .music : .video, origin: origin,
                            maxConnections: connections, wantsToRun: startNow, folder: folder, isPrivate: isPrivate,
                            kind: .media, playlistTitle: playlistTitle, displayName: info.title)
    }

    /// Lists `item` at `index`, saves it with its credentials (unless private) and lets the queue start it.
    func insert(_ item: DownloadItem, at index: Int, credentials: [String: String]) {
        items.insert(item, at: min(max(0, index), items.count))
        item.credentials = credentials.filter { HTTPHeaders.isSensitive($0.key) && !$0.value.isEmpty }
        if !item.isPrivate {
            item.hasStoredCredentials = credentials.contains { HTTPHeaders.isSensitive($0.key) && !$0.value.isEmpty }
            savedStates[item.id] = item.snapshot.state
            let record = record(for: item)
            let recorder = self.recorder
            Task {
                // The Keychain may refuse; the item then says so, which picks the right message on a later 401/403.
                item.hasStoredCredentials = await recorder.added(record, credentials: credentials, isPrivate: false)
            }
        }
        scheduleQueue()
    }

    /// Adds a download brought back from the saved list below those already listed (the list is newest first).
    func appendRestored(_ item: DownloadItem) {
        items.append(item)
        savedStates[item.id] = item.snapshot.state
    }

    /// The sanitised browser-supplied name, or nil when it is absent or blank.
    private static func inferenceName(_ preferred: String?) -> String? {
        guard let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return ContentDisposition.sanitize(trimmed)
    }

    // MARK: Actions

    func pause(_ item: DownloadItem) {
        guard !item.isMerging else { return }        // a merge can't be paused; it finishes on its own
        item.wantsToRun = false
        item.startRequested = false
        Task { await item.task.pause() }
    }

    /// Resume; for a restored failure or a file that changed on the server, Retry / Restart (`retry`).
    func resume(_ item: DownloadItem) {
        if item.isArchived || item.needsRestart {
            retry(item)
            return
        }
        item.wantsToRun = true
        scheduleQueue()
    }

    /// Stops a download and deletes its partial data. A finished one only leaves the list; its file stays.
    func remove(_ item: DownloadItem) {
        guard item.status != .completed else {
            removeFromList(item)
            return
        }
        item.wantsToRun = false
        item.startRequested = false
        let inUse = pathsInUse(excluding: item)
        Task { await Self.discardData(of: item.task, keeping: inUse) }
        forget(item)
    }

    /// Takes a finished download off the list. The file stays on disk.
    func removeFromList(_ item: DownloadItem) {
        guard item.status == .completed else { return }
        forget(item)
    }

    /// Takes every finished download among `shown` off the list. Failed and unfinished ones stay; no file is deleted.
    func clearCompleted(in shown: [DownloadItem]) {
        for item in shown where item.status == .completed { removeFromList(item) }
    }

    /// Takes `item` off the list and out of the saved list, and deletes its Keychain item.
    func forget(_ item: DownloadItem) {
        unlist(item)
        let recorder = self.recorder, id = item.id, isPrivate = item.isPrivate
        Task { await recorder.removed(id: id, isPrivate: isPrivate) }
    }

    /// Takes `item` off the list. With no saved state left, nothing saves it again (`noteForLibrary`).
    func unlist(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
        savedStates[item.id] = nil
    }

    /// The files listed downloads other than `item` use: a failed download's leftovers that a newer download took over
    /// (the same name was free again) are never deleted.
    func pathsInUse(excluding item: DownloadItem) -> Set<URL> {
        var paths: Set<URL> = []
        for other in items where other.id != item.id && other.kind == .file {
            let destination = other.snapshot.destination ?? other.folder.appending(path: other.snapshot.fileName)
            let part = destination.appendingPathExtension("slpart")
            paths.formUnion([destination, part, part.appendingPathExtension("json")])
        }
        return paths
    }

    /// Discards `task`'s partial data; a restored failure's leftovers only when no listed download uses them.
    nonisolated static func discardData(of task: any DownloadTask, keeping inUse: Set<URL>) async {
        if let archived = task as? ArchivedTask {
            await archived.discard(keeping: inUse)
        } else {
            await task.discard()
        }
    }

    func pauseAll() { items.filter { $0.status == .downloading || $0.status == .queued }.forEach(pause) }

    /// Resumes what can continue. Restored failures without data (Retry) and files changed on the server (Restart)
    /// start over and delete partial data, so only their own button does that.
    func resumeAll() {
        items.filter { ($0.status == .paused || $0.status == .failed) && !$0.isArchived && !$0.needsRestart }.forEach(resume)
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Quitting: stops polling and the queue, so nothing starts while downloads are being paused.
    func stopQueue() {
        queueStopped = true
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        let now = ContinuousClock.now
        let elapsed = min((now - lastRefresh) / .seconds(1), 2)   // a stalled poll mustn't inflate the average
        lastRefresh = now
        // Every write below is guarded: an @Observable property notifies its observers on any write, even of an
        // equal value, and an idle tick must not re-render the main window (a re-render there closes open menus
        // in the picker sheet).
        for item in items {
            let snapshot = await item.task.snapshot()
            if let media = item.task as? MediaDownload {
                let mediaSnapshot = await media.mediaSnapshot()
                if item.media != mediaSnapshot { item.media = mediaSnapshot }
            }
            let previous = item.snapshot
            if previous != snapshot { item.snapshot = snapshot }
            switch snapshot.state {
            case .downloading, .probing, .finishing:
                if item.startRequested { item.startRequested = false }
                if snapshot.state == .downloading, previous.state == .downloading {
                    item.activeSeconds += elapsed
                    let received = max(0, snapshot.downloaded - previous.downloaded)
                    if received > 0 { item.sessionBytes += received }
                }
            case .completed, .failed:
                // Only on a transition, so resuming an already-failed job isn't reset.
                if previous.state != snapshot.state {
                    item.startRequested = false
                    item.wantsToRun = false
                    if snapshot.state == .completed { item.completedAt = .now }
                }
            default:
                break
            }
            noteForLibrary(item, previous: previous)
        }
        let speed = items.reduce(0) { $0 + $1.snapshot.bytesPerSecond }
        if speed != totalSpeed { totalSpeed = speed }
        let connections = items.reduce(0) { $0 + $1.snapshot.lanes.count }
        if connections != activeConnections { activeConnections = connections }
        tickCount += 1
        if tickCount % 4 == 0, let next = Self.history(throughputHistory, adding: speed) {
            throughputHistory = next
        }
        scheduleQueue()
    }

    /// The speed graph with `sample` added (the oldest dropped past 120), or nil when that changes nothing: an idle
    /// graph (all zeros) taking another zero, so idle ticks publish nothing.
    static func history(_ history: [Double], adding sample: Double, capacity: Int = 120) -> [Double]? {
        var next = history
        next.append(sample)
        if next.count > capacity { next.removeFirst(next.count - capacity) }
        return next == history ? nil : next
    }

    /// Main queue: oldest first, at most `maxConcurrent` running (default 4).
    private func scheduleQueue() {
        guard !queueStopped else { return }
        var running = items.filter { $0.status == .downloading }.count
        for item in items.reversed() where item.status == .queued && running < maxConcurrent {
            item.startRequested = true
            running += 1
            Task {
                // Quitting (or a pause) may have come between scheduling and this task running: start nothing then.
                guard !queueStopped, item.wantsToRun else {
                    item.startRequested = false
                    return
                }
                // start() returns only after the probe finishes. A job that fails here can
                // go .failed -> .failed between two polls, which refresh() never sees as a
                // transition, so clear intent here or the item stays "downloading" forever.
                await item.task.start()
                let snapshot = await item.task.snapshot()
                item.snapshot = snapshot
                if case .failed = snapshot.state {
                    item.startRequested = false
                    item.wantsToRun = false
                } else if !item.wantsToRun {
                    // pause()/remove() may have been sent before start() ran; re-check intent.
                    await item.task.pause()
                }
            }
        }
    }

    private func applySpeedLimit() {
        let limit = currentSpeedLimit
        for item in items { Task { await item.task.setSpeedLimit(limit) } }
    }
}
