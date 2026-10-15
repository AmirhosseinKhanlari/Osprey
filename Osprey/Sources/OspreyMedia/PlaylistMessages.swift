import Foundation

/// A playlist entry that wasn't added, and why.
public struct PlaylistFailure: Sendable, Equatable {
    public enum Reason: Error, Sendable, Equatable {
        case protected, needsFFmpeg, unreadable

        public init(_ error: MediaError) { self = error == .drmProtected ? .protected : .unreadable }

        public init(_ problem: PlaylistEntryProblem) {
            switch problem {
            case .protected: self = .protected
            case .needsFFmpeg: self = .needsFFmpeg
            case .noMatchingQuality: self = .unreadable
            }
        }

        public var label: String {
            switch self {
            case .protected: "protected (DRM)"
            case .needsFFmpeg: "needs ffmpeg"
            case .unreadable: "couldn’t be read"
            }
        }
    }

    public var title: String
    public var reason: Reason

    public init(title: String, reason: Reason) {
        self.title = title
        self.reason = reason
    }

    /// The notification after a playlist's entries were added. A private request names neither the playlist nor
    /// its videos.
    public static func notificationText(playlist: String, failures: [PlaylistFailure], isPrivate: Bool,
                                        kind: MediaKind = .video) -> (title: String, body: String) {
        let count = failures.count
        let videos = kind.count(count)
        if isPrivate {
            let protected = failures.filter { $0.reason == .protected }.count
            let note: String
            if protected == 0 {
                note = ""
            } else if protected == count {
                note = count == 1 ? " It’s protected (DRM)." : " They’re protected (DRM)."
            } else {
                note = protected == 1 ? " 1 is protected (DRM)." : " \(protected) are protected (DRM)."
            }
            return ("Some playlist \(kind.plural) weren’t added", "\(videos) from a private window couldn’t be added.\(note)")
        }
        let title = "\(videos) from “\(playlist)” \(count == 1 ? "wasn’t" : "weren’t") added"
        let listed = failures.prefix(3).map { "\($0.title) — \($0.reason.label)" }.joined(separator: "\n")
        return (title, listed + (count > 3 ? "\n…and \(count - 3) more" : ""))
    }
}

/// One playlist whose entries are being looked up and added in the background.
public struct PlaylistBatchProgress: Sendable, Equatable {
    /// nil for a private request: its title stays out of the window.
    public var playlistTitle: String?
    public var done: Int
    public var total: Int
    /// What the entries are (from the chosen quality): tracks for an audio format, else videos.
    public var kind: MediaKind

    public init(playlistTitle: String?, done: Int, total: Int, kind: MediaKind = .video) {
        self.playlistTitle = playlistTitle
        self.done = done
        self.total = total
        self.kind = kind
    }

    /// "Adding 3 of 10 from “Title”…" for one playlist; "Adding 12 videos from 2 playlists…" for several.
    public static func bannerText(_ batches: [PlaylistBatchProgress]) -> String? {
        guard !batches.isEmpty else { return nil }
        if batches.count == 1, let batch = batches.first {
            let progress = "Adding \(min(batch.done + 1, batch.total)) of \(batch.total)"
            return batch.playlistTitle.map { "\(progress) from “\($0)”…" } ?? "\(progress) playlist \(batch.kind.plural)…"
        }
        let left = batches.reduce(0) { $0 + max(0, $1.total - $1.done) }
        let kinds = Set(batches.map(\.kind.singular))
        let kind = kinds.count == 1 ? batches[0].kind : MediaKind.unknown
        return "Adding \(kind.count(left)) from \(batches.count) playlists…"
    }
}
