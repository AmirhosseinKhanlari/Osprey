import Foundation
import OspreyEngine
import OspreyMedia

/// What a saved download becomes at launch.
public enum RestoreAction: Sendable, Equatable {
    /// A file with its sidecar: `DownloadJob(resuming:)`, paused, or showing its failure for a failed one.
    case resumeFile(ResumeState)
    /// An unfinished file without a usable sidecar: a fresh job for the same URL and folder, from zero, paused.
    case restartFile
    /// A video with its hidden part folder: `MediaDownload(resuming:)`, paused, or showing its failure for a failed one.
    case resumeMedia(MediaRecord)
    /// A completed download, or a failed one without usable data, listed as it ended (`ArchivedTask`).
    /// `missingFile`: the completed file is gone.
    case archived(missingFile: Bool)

    /// It comes back as a download that can continue: its credentials and hidden folder stay.
    public var resumes: Bool {
        switch self {
        case .resumeFile, .restartFile, .resumeMedia: true
        case .archived: false
        }
    }
}

/// The launch decisions, without touching the disk itself (the caller passes the file checks).
public enum RestorePlanner {
    /// - Completed: listed as finished, or "File missing".
    /// - Unfinished or failed file: resumes from its sidecar when the sidecar is there and is this download's
    ///   (`sidecarMatches`). Without one, an unfinished file whose final file is on disk at its full size finished just
    ///   before a crash (`.archived`, to be saved with `finished(_:fileSize:at:)`); any other unfinished file starts
    ///   over, and a failed one is listed for Retry.
    /// - Unfinished video: resumes. Failed video: resumes when its hidden part folder is still there, else Retry.
    public static func plan(_ record: DownloadRecord, fileExists: (URL) -> Bool, sidecarExists: (URL) -> Bool,
                            fileSize: (URL) -> Int64? = RestorePlanner.size(of:),
                            loadSidecar: (URL) -> ResumeState? = { try? ResumeStore.load(from: $0) }) -> RestoreAction {
        let failed = if case .failed = record.state { true } else { false }
        if record.state == .completed { return .archived(missingFile: !fileExists(record.destination)) }
        switch record.kind {
        case .media:
            guard let media = record.media else { return .archived(missingFile: false) }
            if failed && !fileExists(hiddenFolder(of: media)) { return .archived(missingFile: false) }
            return .resumeMedia(media)
        case .file:
            let sidecar = sidecarURL(for: record.destination)
            let present = sidecarExists(sidecar)
            if present, let state = loadSidecar(sidecar), sidecarMatches(state, record) { return .resumeFile(state) }
            if failed { return .archived(missingFile: false) }
            if !present, finishedOnDisk(record, fileExists: fileExists, fileSize: fileSize) { return .archived(missingFile: false) }
            return .restartFile
        }
    }

    /// The sidecar is this download's: same destination, and its URL or the address it was given is the record's.
    public static func sidecarMatches(_ state: ResumeState, _ record: DownloadRecord) -> Bool {
        state.destination.standardizedFileURL == record.destination.standardizedFileURL
            && (state.originalURL == record.url || state.url == record.url)
    }

    /// An unfinished file found complete on disk: the engine renamed it into place, and the app quit or crashed before
    /// the list saved it. Known size: the file has exactly that size. Unknown size: the download was probed (it
    /// received bytes, so the name was chosen free) and the file holds at least what was saved.
    static func finishedOnDisk(_ record: DownloadRecord, fileExists: (URL) -> Bool, fileSize: (URL) -> Int64?) -> Bool {
        guard record.state == .paused, record.kind == .file, fileExists(record.destination),
              let size = fileSize(record.destination) else { return false }
        if let total = record.totalSize { return size == total }
        return record.downloaded > 0 && size >= record.downloaded
    }

    /// `record` saved as finished at `date` (see `finishedOnDisk`).
    public static func finished(_ record: DownloadRecord, fileSize: Int64?, at date: Date) -> DownloadRecord {
        var record = record
        record.state = .completed
        record.completedAt = date
        record.downloaded = record.totalSize ?? fileSize ?? record.downloaded
        return record
    }

    /// The size of the file at `url`, or nil.
    public static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
    }

    /// `<destination>.slpart.json`, the engine's resume sidecar.
    public static func sidecarURL(for destination: URL) -> URL {
        destination.appendingPathExtension("slpart").appendingPathExtension("json")
    }

    /// `<folder>/.osprey-media-<uuid>`, a video's hidden part folder.
    public static func hiddenFolder(of media: MediaRecord) -> URL {
        media.folder.appending(path: ".osprey-media-\(media.hiddenFolderID.uuidString)", directoryHint: .isDirectory)
    }

    /// A download that can continue, as the list shows it until its task reports: the saved progress, paused, or with
    /// its failure message for a failed one.
    public static func resumableSnapshot(for record: DownloadRecord) -> DownloadSnapshot {
        let state: DownloadState = if case .failed(let message) = record.state { .failed(message) } else { .paused }
        return DownloadSnapshot(state: state, fileName: record.destination.lastPathComponent, totalSize: record.totalSize,
                                downloaded: record.downloaded, bytesPerSecond: 0, segments: [], lanes: [],
                                acceptsRanges: false, etag: nil, destination: nil)
    }

    /// A finished or failed download's fixed snapshot. Only a completed file that is still there has a destination, so
    /// Open and Show in Finder appear only for it.
    public static func archivedSnapshot(for record: DownloadRecord, missingFile: Bool) -> DownloadSnapshot {
        let state: DownloadState = switch record.state {
        case .completed: .completed
        case .failed(let message): .failed(message)
        case .paused: .failed("This download couldn't be restored.")
        }
        let done = record.state == .completed
        return DownloadSnapshot(state: state, fileName: record.destination.lastPathComponent, totalSize: record.totalSize,
                                downloaded: done ? (record.totalSize ?? record.downloaded) : record.downloaded,
                                bytesPerSecond: 0, segments: [], lanes: [], acceptsRanges: false, etag: nil,
                                destination: done && !missingFile ? record.destination : nil)
    }

    /// What a failed download left on disk, deleted when it is removed or retried. Call it then, not at launch: a new
    /// download may have taken the name since.
    /// - A file: its `.slpart` and sidecar, only while the sidecar is this record's (`sidecarMatches`).
    /// - A video: its hidden part folder, named after the record's own id.
    public static func leftovers(for record: DownloadRecord,
                                 loadSidecar: (URL) -> ResumeState? = { try? ResumeStore.load(from: $0) }) -> [URL] {
        guard case .failed = record.state else { return [] }
        switch record.kind {
        case .file:
            let sidecar = sidecarURL(for: record.destination)
            guard let state = loadSidecar(sidecar), sidecarMatches(state, record) else { return [] }
            return [record.destination.appendingPathExtension("slpart"), sidecar]
        case .media:
            guard let media = record.media else { return [] }
            return [hiddenFolder(of: media)]
        }
    }

    /// The downloads whose Keychain items stay at launch: those that come back able to continue. Everything else is an
    /// orphan.
    public static func credentialIDsToKeep(_ actions: [UUID: RestoreAction]) -> Set<UUID> {
        Set(actions.filter { $0.value.resumes }.keys)
    }

    /// The hidden part folders the launch sweep must not delete: those of videos that resume.
    public static func hiddenFolderIDsToKeep(_ actions: some Collection<RestoreAction>) -> Set<UUID> {
        Set(actions.compactMap { if case .resumeMedia(let media) = $0 { media.hiddenFolderID } else { nil } })
    }
}
