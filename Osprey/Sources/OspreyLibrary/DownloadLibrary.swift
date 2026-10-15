import Foundation
import OspreyEngine
import os

/// The saved download list: `~/Library/Application Support/Osprey/Downloads/library.json`,
/// `{"version": 1, "items": [DownloadRecord]}`.
///
/// - The file is read once, when the library is created; `load()` returns what was read, newest first.
/// - `update` and `remove` change the list in memory and write it at most once per `debounce`: the first change after a
///   write schedules the next write `debounce` later, and every change until then joins it. `flush()` writes at once.
/// - Each write goes to a temporary file (mode 0600) that is renamed over the old one; the folder is 0700. Temporary
///   files a crash left behind are deleted when the library is created. A write that fails is tried again, with
///   backoff, up to `maxWriteRetries` times; the change stays pending meanwhile.
/// - A removed id stays removed: a later `update` for it (a save that was already on its way) is ignored. A download
///   that starts again (Retry) gets a new id.
/// - A file of another version is moved aside to `library.v<N>-<date>.json`, an unreadable one to
///   `library.corrupt-<date>.json`; both load as an empty list. A single unreadable record is skipped. Nothing here
///   ever crashes the app.
public actor DownloadLibrary {
    public static let currentVersion = 1
    public static let fileName = "library.json"
    /// Retries of a failed write before waiting for the next change.
    public static let maxWriteRetries = 5

    /// `~/Library/Application Support/Osprey/Downloads`, or `Osprey/Downloads-Debug` for a Debug build, so a Debug build
    /// never shares the installed app's list.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: defaultFolderPath, directoryHint: .isDirectory)
    }

    #if DEBUG
    static let defaultFolderPath = "Osprey/Downloads-Debug"
    #else
    static let defaultFolderPath = "Osprey/Downloads"
    #endif

    public nonisolated let folder: URL
    public nonisolated var fileURL: URL { folder.appending(path: Self.fileName) }

    private nonisolated let loaded: [DownloadRecord]
    private let debounce: Duration
    private let now: @Sendable () -> Date
    private var records: [UUID: DownloadRecord]
    private var dirty = false
    private var pendingWrite: Task<Void, Never>?
    /// Ids removed in this session; `update` ignores them.
    private var removedIDs: Set<UUID> = []
    /// Writes that reached the disk (read by the tests).
    private(set) var writeCount = 0
    /// Failed writes since the last one that succeeded.
    private(set) var failedWrites = 0

    private static let log = Logger(subsystem: "com.akhanlari.osprey", category: "library")

    public init(folder: URL = DownloadLibrary.defaultFolder, debounce: Duration = .seconds(1),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.debounce = debounce
        self.now = now
        AtomicFile.removeStaleTemporaryFiles(in: folder, for: Self.fileName)
        let read = Self.read(folder: folder, now: now())
        loaded = read
        records = Dictionary(read.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The records the file held when this library was created, newest first.
    public nonisolated func load() -> [DownloadRecord] { loaded }

    public func update(_ record: DownloadRecord) {
        guard !removedIDs.contains(record.id) else { return }
        records[record.id] = record
        scheduleWrite()
    }

    public func remove(id: UUID) {
        removedIDs.insert(id)
        guard records.removeValue(forKey: id) != nil else { return }
        scheduleWrite()
    }

    /// Writes any pending change now.
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    // MARK: Writing

    private func scheduleWrite() {
        dirty = true
        schedule(after: debounce)
    }

    private func schedule(after delay: Duration) {
        guard pendingWrite == nil else { return }               // this change joins the write already scheduled
        pendingWrite = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.pendingWrite = nil
            self.write()
        }
    }

    private func write() {
        guard dirty else { return }
        do {
            try AtomicFile.prepareFolder(folder)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(StoredList(version: Self.currentVersion, items: Self.newestFirst(Array(records.values))))
            try AtomicFile.write(data, to: fileURL)
            dirty = false
            writeCount += 1
            failedWrites = 0
        } catch {
            failedWrites += 1
            Self.log.error("Couldn't save the download list: \(error.localizedDescription, privacy: .public)")
            // Still dirty: try again later, waiting twice as long each time, up to the limit. The next change then
            // schedules a write as usual.
            guard failedWrites <= Self.maxWriteRetries else { return }
            schedule(after: debounce * (1 << min(failedWrites, 6)))
        }
    }

    private static func newestFirst(_ records: [DownloadRecord]) -> [DownloadRecord] {
        records.sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: Reading

    private static func read(folder: URL, now: Date) -> [DownloadRecord] {
        let file = folder.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return [] }
        guard let data = try? Data(contentsOf: file) else {
            log.error("Couldn't read the download list")
            return []
        }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            moveAside(file, label: "corrupt", now: now)
            return []
        }
        guard probe.version == currentVersion else {
            moveAside(file, label: "v\(probe.version)", now: now)
            return []
        }
        guard let list = try? decoder.decode(LoadedList.self, from: data) else {
            moveAside(file, label: "corrupt", now: now)
            return []
        }
        let records = list.items.compactMap(\.value)
        if records.count < list.items.count {
            log.error("Skipped \(list.items.count - records.count, privacy: .public) unreadable downloads in the saved list")
        }
        return newestFirst(records)
    }

    private static func moveAside(_ file: URL, label: String, now: Date) {
        do {
            let target = try AtomicFile.moveAside(file, label: label, now: now)
            log.error("Moved an unreadable download list aside: \(target.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Couldn't move an unreadable download list aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct StoredList: Encodable {
    let version: Int
    let items: [DownloadRecord]
}

private struct VersionProbe: Decodable {
    let version: Int
}

private struct LoadedList: Decodable {
    let version: Int
    let items: [LossyRecord]
}

/// Skips a record that can't be read, or a video without the media record it needs to rebuild itself.
private struct LossyRecord: Decodable {
    let value: DownloadRecord?

    init(from decoder: any Decoder) throws {
        let record = try? DownloadRecord(from: decoder)
        value = record.flatMap { $0.kind == .media && $0.media == nil ? nil : $0 }
    }
}
