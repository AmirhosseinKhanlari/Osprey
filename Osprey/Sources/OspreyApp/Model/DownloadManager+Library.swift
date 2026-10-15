import Foundation
import OspreyEngine
import OspreyLibrary
import OspreyMedia

/// Keeping the list across restarts: each download's saved form, saving it as it changes, bringing the list back at
/// launch, and Retry for downloads that can't simply resume.
extension DownloadManager {
    // MARK: Saving

    /// `item` as the saved list keeps it. A running download is saved paused.
    func record(for item: DownloadItem) -> DownloadRecord {
        let snapshot = item.snapshot
        var media = item.archivedMedia
        if let download = item.task as? MediaDownload {
            let phase = item.media.map { MediaRecord.Phase($0) } ?? .downloading
            media = download.record(phase: phase, warning: item.media?.warning)
        }
        return DownloadRecord(id: item.id, kind: item.kind == .media ? .media : .file, url: item.url,
                              category: item.category.rawValue, origin: item.origin.saved,
                              maxConnections: item.maxConnections, playlistTitle: item.playlistTitle, addedAt: item.addedAt,
                              completedAt: item.completedAt, state: DownloadRecord.state(for: snapshot.state),
                              destination: snapshot.destination ?? item.folder.appending(path: snapshot.fileName),
                              downloaded: snapshot.downloaded, totalSize: snapshot.totalSize,
                              activeSeconds: item.activeSeconds, hasStoredCredentials: item.hasStoredCredentials,
                              media: media, preferredFilename: item.preferredFilename, headers: item.requestHeaders,
                              queueID: item.queueID == Queue.mainID ? nil : item.queueID,
                              waitingInQueue: Self.isWaiting(item))
    }

    /// Unfinished and meant to run (queued, running, or paused by its queue), or restored waiting and untouched since.
    static func isWaiting(_ item: DownloadItem) -> Bool {
        switch item.snapshot.state {
        case .completed, .failed: false
        default: item.wantsToRun || item.waitingInQueue
        }
    }

    /// Saves `item` now, for a change its state doesn't show: a pause or resume of a download that isn't running, or a
    /// move to another queue.
    func saveNow(_ item: DownloadItem) {
        guard !item.isPrivate, savedStates[item.id] != nil else { return }
        let record = record(for: item)
        let recorder = self.recorder
        Task { await recorder.changed(record, isPrivate: false, flush: true) }
    }

    /// Saves `item` when its state changed since the last save (flushed for a pause, failure or completion), or when it
    /// received bytes while running (written within the library's 1 s window). Private items are never saved, and
    /// neither is an item no longer listed: `refresh()` awaits each task, and the user may remove the item meanwhile.
    func noteForLibrary(_ item: DownloadItem, previous: DownloadSnapshot) {
        guard !item.isPrivate, savedStates[item.id] != nil else { return }
        let state = item.snapshot.state
        let changed = savedStates[item.id] != state
        let progressed = state == .downloading && item.snapshot.downloaded != previous.downloaded
        guard changed || progressed else { return }
        savedStates[item.id] = state
        let flush: Bool = switch state {
        case .paused, .completed, .failed: changed
        default: false
        }
        let record = record(for: item)
        let recorder = self.recorder
        Task { await recorder.changed(record, isPrivate: false, flush: flush) }
    }

    // MARK: Restoring

    /// Brings the saved list back at launch. Call it once, before the main window shows and before the media sweep.
    /// - Unfinished downloads come back paused, resuming from their partial data.
    /// - Failed downloads whose partial data is still there come back failed, and Resume continues them.
    /// - Finished downloads, and failed ones without data, come back as they ended (Retry downloads them again).
    /// - A file that finished just before a crash (renamed, not yet saved) comes back finished, and is saved so.
    /// - Afterwards, off the main thread, Keychain items of downloads that can't continue are deleted.
    ///
    /// The Keychain is read here, on the main thread, in one pass over the downloads that resume with stored sign-in
    /// headers (most have none): a job and a media download take their headers when they are made.
    func restore() {
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        var planned: [(record: DownloadRecord, action: RestoreAction)] = []
        var finishedAtLaunch: [DownloadRecord] = []
        for saved in library.load() {
            var record = saved
            let action = RestorePlanner.plan(record, fileExists: exists, sidecarExists: exists)
            if record.state == .paused, case .archived = action {
                record = RestorePlanner.finished(record, fileSize: RestorePlanner.size(of: record.destination), at: Date())
                finishedAtLaunch.append(record)
            }
            planned.append((record, action))
        }
        let actions = Dictionary(planned.map { ($0.record.id, $0.action) }, uniquingKeysWith: { first, _ in first })
        let keep = RestorePlanner.credentialIDsToKeep(actions)
        restoredHiddenFolderIDs = RestorePlanner.hiddenFolderIDsToKeep(actions.values)
        var credentials: [UUID: [String: String]] = [:]
        for (record, action) in planned where action.resumes && record.hasStoredCredentials {
            credentials[record.id] = vault.headers(id: record.id)
        }
        let queueIDs = Set(queues.map(\.id))
        for (record, action) in planned {
            let item = restoredItem(record, action: action, credentials: credentials[record.id] ?? [:])
            let placement = RestorePlanner.queuePlacement(for: record, existing: queueIDs)
            item.queueID = placement.queueID
            item.waitingInQueue = placement.waiting
            appendRestored(item)
        }
        let recorder = self.recorder
        Task(priority: .utility) {
            await recorder.pruneCredentials(keeping: keep)
            for record in finishedAtLaunch {
                await recorder.changed(record, isPrivate: false, flush: record.id == finishedAtLaunch.last?.id)
            }
        }
    }

    private func restoredItem(_ record: DownloadRecord, action: RestoreAction,
                              credentials: [String: String]) -> DownloadItem {
        let failure: String? = if case .failed(let message) = record.state { message } else { nil }
        let task: any DownloadTask
        var missingFile = false
        var archived = false
        switch action {
        case .resumeFile(let saved):
            var options = DownloadOptions()
            options.maxConnections = record.maxConnections
            options.speedLimit = currentSpeedLimit
            options.headers = credentials             // the job adds the sidecar's own non-secret headers
            options.preferredFilename = record.preferredFilename
            task = DownloadJob(id: record.id, resuming: saved, options: options, failure: failure)
        case .restartFile:
            var options = DownloadOptions()
            options.maxConnections = record.maxConnections
            options.speedLimit = currentSpeedLimit
            options.headers = record.headers.merging(credentials) { _, secret in secret }
            options.preferredFilename = record.preferredFilename
            task = DownloadJob(id: record.id, request: URLRequest(url: record.url),
                               folder: record.destination.deletingLastPathComponent(), options: options)
        case .resumeMedia(let saved):
            let cookie = credentials.first { $0.key.lowercased() == "cookie" }?.value
            task = MediaDownload(resuming: saved, id: record.id, pageURL: record.url, cookieHeader: cookie,
                                 speedLimit: currentSpeedLimit, tools: mediaTools, extractor: MediaExtractor(tools: mediaTools),
                                 failure: failure)
        case .archived(let missing):
            missingFile = missing
            archived = true
            // Worked out when it is removed or retried: by then a new download may have taken the name.
            task = ArchivedTask(id: record.id, snapshot: RestorePlanner.archivedSnapshot(for: record, missingFile: missing)) {
                RestorePlanner.leftovers(for: record)
            }
        }
        let item = DownloadItem(task: task, url: record.url, category: Category(rawValue: record.category) ?? .other,
                                origin: DownloadOrigin(record.origin), maxConnections: record.maxConnections,
                                wantsToRun: false, folder: record.media?.folder ?? record.destination.deletingLastPathComponent(),
                                kind: record.kind == .media ? .media : .file, playlistTitle: record.playlistTitle,
                                displayName: record.destination.lastPathComponent, preferredFilename: record.preferredFilename,
                                requestHeaders: record.headers, addedAt: record.addedAt, isRestored: true,
                                archivedMedia: archived ? record.media : nil)
        item.snapshot = archived ? RestorePlanner.archivedSnapshot(for: record, missingFile: missingFile)
                                 : RestorePlanner.resumableSnapshot(for: record)
        item.completedAt = record.completedAt
        item.activeSeconds = record.activeSeconds
        item.hasStoredCredentials = record.hasStoredCredentials
        item.credentials = credentials
        item.fileMissing = missingFile
        return item
    }

    // MARK: Retry

    /// Downloads `item` again as a new download in its place:
    /// - a restored failure without partial data
    /// - a restored finished file that is missing
    /// - a file that changed on the server (Restart)
    ///
    /// Its partial data is deleted first (a restored failure's only when no listed download uses it), and its sign-in
    /// headers move to the new download: from the Keychain, read off the main thread, or else from memory.
    func retry(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let inMemory = item.credentials
        let inUse = pathsInUse(excluding: item)
        let recorder = self.recorder, id = item.id, isPrivate = item.isPrivate
        unlist(item)
        Task { [self] in
            // Read before the removal deletes them. The recorder is an actor: the Keychain call runs off the main thread.
            let stored = isPrivate ? [:] : await recorder.credentials(id: id)
            await recorder.removed(id: id, isPrivate: isPrivate)
            await Self.discardData(of: item.task, keeping: inUse)
            let credentials = stored.isEmpty ? inMemory : stored
            guard let fresh = replacement(for: item, credentials: credentials) else { return }
            fresh.queueID = queues.contains { $0.id == item.queueID } ? item.queueID : Queue.mainID   // stays in its queue
            fresh.startedByUser = fresh.queueID != Queue.mainID                                     // and starts now
            insert(fresh, at: min(index, items.count), credentials: credentials)
        }
    }

    private func replacement(for item: DownloadItem, credentials: [String: String]) -> DownloadItem? {
        switch item.kind {
        case .file:
            return makeFileItem(url: item.url, folder: item.folder, category: item.category, connections: item.maxConnections,
                                origin: item.origin, headers: item.requestHeaders.merging(credentials) { _, secret in secret },
                                preferredFilename: item.preferredFilename, isPrivate: item.isPrivate, startNow: true)
        case .media:
            let cookie = credentials.first { $0.key.lowercased() == "cookie" }?.value
            if let live = item.task as? MediaDownload {
                return makeMediaItem(pageURL: item.url, info: live.info, plan: live.plan, folder: live.folder,
                                     cookieHeader: cookie, isPrivate: item.isPrivate, playlistTitle: item.playlistTitle,
                                     startNow: true, origin: item.origin)
            }
            guard let saved = item.archivedMedia else { return nil }
            return makeMediaItem(pageURL: item.url, info: saved.video.mediaInfo, plan: saved.plan, folder: saved.folder,
                                 cookieHeader: cookie, isPrivate: false, playlistTitle: item.playlistTitle, startNow: true,
                                 origin: item.origin)
        }
    }

    // MARK: Quitting

    /// Pauses every download (private ones are discarded with their partial files), saves the list and flushes it,
    /// within `QuitSequence.timeout`. Returns false when the time ran out.
    @discardableResult
    func prepareForQuit(timeout: Duration = QuitSequence.timeout) async -> Bool {
        stopQueue()
        // A queue start already on its way checks these and starts nothing (and pauses a job whose start was sent).
        for item in items {
            if item.wantsToRun { item.waitingInQueue = true }   // saved waiting: it runs when its queue next starts
            item.wantsToRun = false
            item.startRequested = false
        }
        let quitting = items.map { QuitItem(task: $0.task, isPrivate: $0.isPrivate) }
        let library = self.library
        return await QuitSequence.run(quitting, timeout: timeout,
                                      persist: { await self.saveAllForQuit() },
                                      flush: { await library.flush() })
    }

    /// Saves every listed, non-private item whose state changed since it was last saved, or that waits in its queue,
    /// from its latest snapshot: a stopped merge is saved `readyToMerge`. Restored finished and failed items
    /// (`ArchivedTask`) never change.
    func saveAllForQuit() async {
        for item in items where !item.isPrivate && !item.isArchived {
            item.snapshot = await item.task.snapshot()
            if let media = item.task as? MediaDownload { item.media = await media.mediaSnapshot() }
            // A download saved waiting is written again, so its waiting intent (set by `prepareForQuit`) is on disk.
            guard let saved = savedStates[item.id], saved != item.snapshot.state || item.waitingInQueue else { continue }
            savedStates[item.id] = item.snapshot.state
            await recorder.changed(record(for: item), isPrivate: false, flush: false)
        }
    }
}
