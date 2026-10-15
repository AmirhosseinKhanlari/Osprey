import Foundation
import Observation
import OspreyEngine
import OspreyLibrary
import OspreyMedia

/// How a download reached Osprey.
enum DownloadOrigin: Equatable {
    /// Typed or pasted into the Add URL sheet.
    case addURL
    /// Handed over by a browser extension; `fromMenu` when the user chose it from the link's context menu.
    case browser(fromMenu: Bool)

    var label: String {
        switch self {
        case .addURL: "Add URL"
        case .browser(let fromMenu): fromMenu ? "Browser · link menu" : "Browser"
        }
    }

    /// The origin the saved list stored.
    init(_ saved: DownloadRecord.Origin) {
        switch saved {
        case .addURL: self = .addURL
        case .browser(let fromMenu): self = .browser(fromMenu: fromMenu)
        }
    }

    /// This origin as the saved list stores it.
    var saved: DownloadRecord.Origin {
        switch self {
        case .addURL: .addURL
        case .browser(let fromMenu): .browser(fromMenu: fromMenu)
        }
    }
}

/// A plain file download, or a video page's streams fetched and merged by a `MediaDownload`.
enum ItemKind: Equatable {
    case file, media
}

enum ItemStatus: String {
    case downloading, queued, paused, completed, failed

    var label: String {
        switch self {
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

@MainActor @Observable
final class DownloadItem: Identifiable {
    let id: UUID
    /// A `DownloadJob` for a file, a `MediaDownload` for a video page, or an `ArchivedTask` for a finished or failed
    /// download brought back from the saved list.
    let task: any DownloadTask
    let kind: ItemKind
    /// For a file the download URL; for media the page it came from.
    let url: URL
    let category: Category
    let origin: DownloadOrigin
    /// Captured from a private browser window: never saved to the list or the Keychain, discarded at quit, and its
    /// sidecar keeps no Referer.
    let isPrivate: Bool
    /// The most connections this download may open (the Add sheet's or Settings' choice).
    let maxConnections: Int
    /// The playlist a media item was picked from, if any.
    let playlistTitle: String?
    /// The folder the download saves into.
    let folder: URL
    /// The name the browser suggested, kept so a download that starts over uses it again.
    let preferredFilename: String?
    /// The request's headers without credentials (those go to the Keychain), kept so a restart sends them again.
    let requestHeaders: [String: String]
    let addedAt: Date
    /// Brought back from the saved list at launch.
    let isRestored: Bool
    /// A finished or failed video from the saved list: what Retry needs to download it again, and its warning.
    let archivedMedia: MediaRecord?
    /// When the download finished, for "Finished 2 min ago".
    var completedAt: Date?
    /// Time spent downloading and bytes received in that time, for the average speed.
    var activeSeconds: Double = 0
    var sessionBytes: Int64 = 0
    var snapshot: DownloadSnapshot
    /// A media item's parts and phase, refreshed with `snapshot`; nil for a file.
    var media: MediaSnapshot?
    /// The user wants this item downloaded (queued or running).
    var wantsToRun: Bool
    /// `start()` was sent and the next snapshot hasn't confirmed it yet.
    var startRequested = false
    /// Its sign-in cookies (`Cookie` / `Authorization`) are in the Keychain.
    var hasStoredCredentials = false
    /// Its sign-in headers, in memory only: never saved, never logged. Retry and Restart use them when the Keychain has
    /// none (a private download, or one whose Keychain store failed).
    @ObservationIgnored var credentials: [String: String] = [:]
    /// A finished download whose file was deleted or moved since: only Retry and Remove from list remain.
    var fileMissing = false
    /// The queue it belongs to (`Queue.mainID` for Main).
    var queueID: UUID
    /// Restored paused from a queue it was waiting in: it runs when that queue next starts. Pausing or resuming it
    /// by hand clears this.
    @ObservationIgnored var waitingInQueue = false
    /// Its queue stopped or is held, and the scheduler sent `pause()`; it keeps `wantsToRun` and runs again with the queue.
    @ObservationIgnored var heldByQueue = false
    /// Resumed or retried by hand in a queue other than Main: it runs now, outside its queue's limit and whether or not
    /// the queue runs. Cleared when it completes, fails, or is paused by hand. Never saved.
    @ObservationIgnored var startedByUser = false

    init(task: any DownloadTask, url: URL, category: Category, origin: DownloadOrigin, maxConnections: Int, wantsToRun: Bool,
         folder: URL, isPrivate: Bool = false, kind: ItemKind = .file, playlistTitle: String? = nil, displayName: String? = nil,
         preferredFilename: String? = nil, requestHeaders: [String: String] = [:], addedAt: Date = Date(),
         isRestored: Bool = false, archivedMedia: MediaRecord? = nil, queueID: UUID = Queue.mainID) {
        self.id = task.id
        self.task = task
        self.kind = kind
        self.playlistTitle = playlistTitle
        self.url = url
        self.category = category
        self.origin = origin
        self.maxConnections = max(1, maxConnections)
        self.wantsToRun = wantsToRun
        self.isPrivate = isPrivate
        self.folder = folder
        self.preferredFilename = preferredFilename
        self.requestHeaders = HTTPHeaders.withoutSensitive(requestHeaders)
        self.addedAt = addedAt
        self.isRestored = isRestored
        self.archivedMedia = archivedMedia
        self.queueID = queueID
        self.snapshot = .placeholder(fileName: displayName
            ?? (url.lastPathComponent.isEmpty ? (url.host() ?? "download") : url.lastPathComponent))
    }

    var host: String { url.host() ?? url.absoluteString }

    var status: ItemStatus {
        switch snapshot.state {
        case .downloading, .probing, .finishing: return .downloading
        case .completed: return .completed
        case .failed: return startRequested ? .downloading : (wantsToRun ? .queued : .failed)
        case .idle, .paused:
            if startRequested { return .downloading }
            return wantsToRun ? .queued : .paused
        }
    }

    var progress: Double {
        guard let total = snapshot.totalSize, total > 0 else { return 0 }
        return min(1, max(0, Double(snapshot.downloaded) / Double(total)))
    }

    /// The failure text: "Changed on the server — Restart", "Needs sign-in — …" for a restored file without cookies,
    /// else the engine's own.
    var errorMessage: String? {
        guard case .failed(let message) = snapshot.state else { return nil }
        guard kind == .file else { return message }
        return ResumeFailureText.message(for: message, restored: isRestored, hasStoredCredentials: hasStoredCredentials) ?? message
    }

    /// The file changed on the server since the partial download began: Resume becomes Restart.
    var needsRestart: Bool {
        guard kind == .file, case .failed(let message) = snapshot.state else { return false }
        return ResumeFailureText.isChangedOnServer(message)
    }

    /// A finished or failed download from the saved list: it can't resume, only be downloaded again (Retry).
    var isArchived: Bool { task is ArchivedTask }

    /// The resume action's name: "Resume", "Retry" for a restored failure, "Restart" for a file that changed.
    var resumeTitle: String { needsRestart ? "Restart" : (isArchived ? "Retry" : "Resume") }

    /// A finished video that left something out: "Saved without subtitles (YouTube refused the captions)".
    var warningMessage: String? { status == .completed ? (media?.warning ?? archivedMedia?.warning)?.userMessage : nil }

    var remaining: Int64? { snapshot.totalSize.map { max(0, $0 - snapshot.downloaded) } }

    /// Average speed while downloading in this session; nil until there is enough to average.
    var averageSpeed: Double? { activeSeconds >= 1 ? Double(sessionBytes) / activeSeconds : nil }

    /// How many connections the bar shows: one per allowed connection, or one when the server
    /// can't serve ranges (or before the probe says).
    var laneCount: Int { snapshot.acceptsRanges ? min(maxConnections, 32) : 1 }
}

enum SidebarFilter: Hashable {
    case all, downloading, queued, paused, completed
    case category(Category)
    /// One queue's downloads; `DownloadManager.title(for:)` gives its name.
    case queue(UUID)

    var title: String {
        switch self {
        case .all: "All downloads"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .paused: "Paused"
        case .completed: "Completed"
        case .category(let category): category.rawValue
        case .queue: "Queue"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray"
        case .downloading: "arrow.down.to.line"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .category(let category): category.symbol
        case .queue(let id): id == Queue.mainID ? "bolt.circle" : "list.bullet.circle"
        }
    }

    @MainActor func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .downloading: item.status == .downloading
        case .queued: item.status == .queued
        case .paused: item.status == .paused || item.status == .failed
        case .completed: item.status == .completed
        case .category(let category): item.category == category
        case .queue(let id): item.queueID == id
        }
    }
}
