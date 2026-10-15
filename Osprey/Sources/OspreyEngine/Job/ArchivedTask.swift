import Foundation

/// A download that only reports how it ended: a finished or failed download brought back from the saved list, or a
/// media part that was already on disk. Starting, pausing and limiting do nothing; discarding deletes its leftovers
/// (a failed download's partial data) and nothing else, never the finished file.
///
/// The leftovers are worked out when discarding, not when the task is made: by then a new download may have taken the
/// same name, and its files must survive.
public actor ArchivedTask: DownloadTask {
    public nonisolated let id: UUID
    private let fixed: DownloadSnapshot
    private let leftovers: @Sendable () -> [URL]

    public init(id: UUID, snapshot: DownloadSnapshot, leftovers: [URL] = []) {
        self.init(id: id, snapshot: snapshot) { leftovers }
    }

    /// `leftovers` runs when the task is discarded.
    public init(id: UUID, snapshot: DownloadSnapshot, leftovers: @escaping @Sendable () -> [URL]) {
        self.id = id
        self.fixed = snapshot
        self.leftovers = leftovers
    }

    public func start() async {}

    public func pause() async {}

    public func setSpeedLimit(_ bytesPerSecond: Double?) {}

    public func snapshot() -> DownloadSnapshot { fixed }

    public func discard() async {
        await discard(keeping: [])
    }

    /// Deletes the leftovers except those in `inUse` (paths a listed download uses).
    public func discard(keeping inUse: Set<URL>) async {
        let kept = Set(inUse.map(\.standardizedFileURL))
        for url in leftovers() where !kept.contains(url.standardizedFileURL) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
