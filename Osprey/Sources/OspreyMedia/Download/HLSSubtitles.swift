import Foundation

/// Subtitles served as an HLS playlist of WebVTT segments (yt-dlp's `m3u8_native` subtitle tracks). YouTube serves its
/// automatic captions this way, and refuses the direct auto-translated ones with HTTP 429. Pure parsing and joining; the
/// fetching is in `MediaDownload`.
enum HLSSubtitles {
    enum Problem: Error, Equatable {
        case notAPlaylist
        case noSegments
        case tooManySegments
        case segmentNotOnTheWeb
    }

    /// At most this many segments (YouTube uses one per 10 minutes).
    static let maxSegments = 1000
    /// A playlist or a segment larger than this is refused.
    static let maxBytes = 20 * 1024 * 1024

    /// The segment addresses: every non-comment line, resolved against the playlist's address. Only http(s) addresses
    /// are accepted, so a playlist can't make Osprey read a local file into the video.
    static func segments(in playlist: String, playlistURL: URL) throws -> [URL] {
        let lines = playlist.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { throw Problem.notAPlaylist }
        var urls: [URL] = []
        for line in lines where !line.isEmpty && !line.hasPrefix("#") {
            guard let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL, MediaURL.isWebURL(url) else {
                throw Problem.segmentNotOnTheWeb
            }
            urls.append(url)
            if urls.count > maxSegments { throw Problem.tooManySegments }
        }
        guard !urls.isEmpty else { throw Problem.noSegments }
        return urls
    }

    /// One WebVTT file from the segments: the first segment's header, then every segment's cues in order. A cue that
    /// spans a boundary is in both segments (their times are absolute), so a later segment's cue that an earlier
    /// segment already had is dropped. Line endings become "\n".
    static func join(_ segments: [String]) -> String {
        var header: String?
        var cues: [String] = []
        var earlier = Set<String>()
        for segment in segments {
            let blocks = segment.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
            if header == nil, let first = blocks.first, first.hasPrefix("WEBVTT") { header = first }
            let segmentCues = blocks.filter { $0.contains("-->") }
            cues += segmentCues.filter { !earlier.contains($0) }
            earlier.formUnion(segmentCues)
        }
        return ([header ?? "WEBVTT"] + cues).joined(separator: "\n\n") + "\n"
    }
}
