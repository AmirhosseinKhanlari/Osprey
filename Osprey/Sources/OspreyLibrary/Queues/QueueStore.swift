import Foundation
import os

/// The queues: `~/Library/Application Support/Osprey/Downloads/queues.json` (`Downloads-Debug` in a Debug build),
/// `{"version":1,"queues":[Queue]}`, written atomically with mode 0600.
///
/// - No file yet: Main and Later.
/// - A file of another version is moved aside to `queues.v<N>-<date>.json`, a corrupt one to
///   `queues.corrupt-<date>.json`, and one that can't be read at all (permissions) to `queues.unreadable-<date>.json`;
///   all load as Main and Later, and the next save never overwrites the user's file.
/// - Main is always first and always present; it can't be scheduled. Duplicate ids keep the first.
public struct QueueStore: Sendable {
    public static let currentVersion = 1
    public static let fileName = "queues.json"

    public let folder: URL
    private let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "com.akhanlari.osprey", category: "queues")

    public init(folder: URL = DownloadLibrary.defaultFolder, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
    }

    public var fileURL: URL { folder.appending(path: Self.fileName) }

    /// Main and Later, as a first launch has them.
    public static var defaults: [Queue] { [.main, .later] }

    public func load() -> [Queue] {
        AtomicFile.removeStaleTemporaryFiles(in: folder, for: Self.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return Self.defaults }
        guard let data = try? Data(contentsOf: fileURL) else { return moveAside(label: "unreadable") }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { return moveAside(label: "corrupt") }
        guard probe.version == Self.currentVersion else { return moveAside(label: "v\(probe.version)") }
        guard let list = try? decoder.decode(StoredQueues.self, from: data) else { return moveAside(label: "corrupt") }
        return Self.normalized(list.queues)
    }

    public func save(_ queues: [Queue]) throws {
        try AtomicFile.prepareFolder(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StoredQueues(version: Self.currentVersion, queues: Self.normalized(queues)))
        try AtomicFile.write(data, to: fileURL)
    }

    /// Main first (added when missing, never scheduled), then the others in order, each id once.
    static func normalized(_ queues: [Queue]) -> [Queue] {
        var main = queues.first { $0.id == Queue.mainID } ?? .main
        main.isMain = true
        main.schedule = .manual
        main.stopTime = nil
        main.onlyOnWiFi = false
        main.onlyOnAC = false
        var seen: Set<UUID> = [Queue.mainID]
        var others: [Queue] = []
        for var queue in queues where seen.insert(queue.id).inserted {
            queue.isMain = false
            others.append(queue)
        }
        return [main] + others
    }

    private func moveAside(label: String) -> [Queue] {
        do {
            let target = try AtomicFile.moveAside(fileURL, label: label, now: now())
            Self.log.error("Moved unreadable queues aside: \(target.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.error("Couldn't move unreadable queues aside: \(error.localizedDescription, privacy: .public)")
        }
        return Self.defaults
    }
}

private struct StoredQueues: Codable {
    let version: Int
    let queues: [Queue]
}

private struct VersionProbe: Decodable {
    let version: Int
}
