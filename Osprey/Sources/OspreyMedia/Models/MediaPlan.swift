import Foundation

public enum Container: String, Sendable, Equatable, Codable {
    case mp4, mkv, webm, m4a, mp3
    public var fileExtension: String { rawValue }
}

public struct MediaPart: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case video, audio, combined }
    public var format: MediaFormat
    public var role: Role
}

/// Codable so a restored download can rebuild itself (see `MediaRecord`).
public struct MediaPlan: Sendable, Equatable, Codable {
    public var parts: [MediaPart]
    public var container: Container
    public var convertToMP3: Bool
    public var subtitle: SubtitleTrack?
    public var subtitleLanguage: String?
    /// Other tracks of the same language, tried in order when `subtitle` can't be fetched (e.g. YouTube's HLS captions
    /// after its direct auto-translated track answers 429).
    public var subtitleAlternates: [SubtitleTrack] = []
    /// Two parts to join, an MP3 conversion, or a subtitle to embed.
    public var needsFFmpeg: Bool { parts.count > 1 || convertToMP3 || subtitle != nil }
}

public struct QualityOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var estimatedBytes: Int64?
    public var estimateIsApproximate: Bool
    public var plan: MediaPlan

    /// True only for an MP4 with H.264/HEVC video and AAC (or no) audio, which QuickTime plays natively.
    public var playsInQuickTime: Bool {
        guard plan.container == .mp4, !plan.convertToMP3,
              let video = plan.parts.first(where: { $0.role != .audio })?.format, video.isH264 || video.isHEVC else { return false }
        if let audio = plan.parts.first(where: { $0.role == .audio })?.format { return audio.isAAC }
        return video.isAAC || video.acodec == "none"
    }
}

public enum QualityCap: Sendable, Equatable, Hashable {
    case best
    case maxHeight(Int)
    case audioM4A
    case audioMP3
}

/// Why a playlist entry wasn't added.
public enum PlaylistEntryProblem: Error, Sendable, Equatable {
    /// DRM: the entry, or (for a video cap) its video, is protected.
    case protected
    /// Nothing matched the cap (say, no AAC audio for M4A).
    case noMatchingQuality
    /// The plan joins, converts or embeds, and ffmpeg isn't installed.
    case needsFFmpeg
}
