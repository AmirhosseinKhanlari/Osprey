import Foundation

/// What a page or playlist holds, for wording: "video(s)", "track(s)", or "item(s)" when it isn't known.
public enum MediaKind: Sendable, Equatable {
    case video, audio, unknown

    public var singular: String {
        switch self {
        case .video: "video"
        case .audio: "track"
        case .unknown: "item"
        }
    }

    public var plural: String { singular + "s" }

    /// "1 track", "3 videos", "2 items".
    public func count(_ n: Int) -> String { n == 1 ? "1 \(singular)" : "\(n) \(plural)" }
}
