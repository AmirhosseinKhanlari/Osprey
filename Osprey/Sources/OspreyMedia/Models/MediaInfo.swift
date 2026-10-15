import Foundation

public struct SubtitleTrack: Decodable, Sendable, Equatable, Hashable {
    public var ext: String
    public var url: URL
    public var name: String?
    /// yt-dlp's `protocol`: "m3u8_native" for YouTube's HLS playlist of WebVTT segments, nil for a plain file.
    public var streamProtocol: String? = nil

    /// An HLS playlist of subtitle segments rather than one subtitle file.
    public var isHLS: Bool {
        streamProtocol?.lowercased().hasPrefix("m3u8") == true || url.path.lowercased().hasSuffix(".m3u8")
    }
}

extension SubtitleTrack {
    enum CodingKeys: String, CodingKey { case ext, url, name, streamProtocol = "protocol" }

    /// A track whose address isn't http(s) fails to decode, so the video's list drops it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ext = try c.decode(String.self, forKey: .ext)
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        streamProtocol = try? c.decodeIfPresent(String.self, forKey: .streamProtocol)
        guard MediaURL.isWebURL(url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an http(s) address")
        }
    }
}

private extension KeyedDecodingContainer {
    /// Accepts an Int, a Double or a numeric string that is finite and not negative (sizes, rates, durations and
    /// dimensions are never negative); anything else is nil.
    func decodeLenientDouble(forKey key: Key) -> Double? {
        let value: Double?
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            value = d
        } else if let s = try? decodeIfPresent(String.self, forKey: key) {
            value = Double(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    func decodeLenientInt64(forKey key: Key) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i >= 0 ? i : nil }
        return decodeLenientDouble(forKey: key).flatMap(MediaText.byteCount)
    }

    func decodeLenientInt(forKey key: Key) -> Int? {
        decodeLenientInt64(forKey: key).flatMap { Int(exactly: $0) }
    }

    /// An Int, a whole Double or a numeric string that may be negative (yt-dlp's preferences use -1); else nil.
    func decodeLenientSignedInt(forKey key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        var value: Double?
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            value = d
        } else if let s = try? decodeIfPresent(String.self, forKey: key) {
            value = Double(s.trimmingCharacters(in: .whitespaces))
        }
        guard let value, value.isFinite, abs(value) < 1e9 else { return nil }
        return Int(exactly: value.rounded())
    }
}

public struct MediaFormat: Decodable, Sendable, Equatable, Hashable {
    public var formatID: String
    public var ext: String
    public var protocolName: String
    /// Fragment-based formats may omit it; yt-dlp downloads those by `format_id`.
    public var url: URL?
    public var httpHeaders: [String: String]
    public var vcodec: String?
    public var acodec: String?
    public var height: Int?
    public var width: Int?
    public var fps: Double?
    public var tbr: Double?
    public var abr: Double?
    public var filesize: Int64?
    public var filesizeApprox: Int64?
    public var hasDRM: Bool
    /// yt-dlp's `has_drm: "maybe"`: kept usable but ranked below unmarked equals.
    public var possiblyProtected: Bool
    public var formatNote: String?
    /// The audio track's language ("en-US", "de"), when the site says. Multi-language videos have one audio format per language.
    public var language: String?
    /// yt-dlp's `language_preference`: higher is preferred (YouTube gives the original track 10, dubs -1).
    public var languagePreference: Int?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id", ext, protocolName = "protocol", url, httpHeaders = "http_headers", vcodec, acodec
        case height, width, fps, tbr, abr, filesize, filesizeApprox = "filesize_approx", hasDRM = "has_drm", formatNote = "format_note"
        case language, languagePreference = "language_preference"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatID = try c.decode(String.self, forKey: .formatID)
        ext = try c.decodeIfPresent(String.self, forKey: .ext) ?? "bin"
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName) ?? "https"
        url = try? c.decodeIfPresent(URL.self, forKey: .url)
        httpHeaders = try c.decodeIfPresent([String: String].self, forKey: .httpHeaders) ?? [:]
        vcodec = try c.decodeIfPresent(String.self, forKey: .vcodec)
        acodec = try c.decodeIfPresent(String.self, forKey: .acodec)
        height = c.decodeLenientInt(forKey: .height)
        width = c.decodeLenientInt(forKey: .width)
        fps = c.decodeLenientDouble(forKey: .fps)
        tbr = c.decodeLenientDouble(forKey: .tbr)
        abr = c.decodeLenientDouble(forKey: .abr)
        filesize = c.decodeLenientInt64(forKey: .filesize)
        filesizeApprox = c.decodeLenientInt64(forKey: .filesizeApprox)
        let drm = DRMFlag(from: c, key: .hasDRM)
        hasDRM = drm.protected
        possiblyProtected = drm.maybe
        formatNote = try c.decodeIfPresent(String.self, forKey: .formatNote)
        let rawLanguage = ((try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil)?.trimmingCharacters(in: .whitespaces)
        language = rawLanguage.flatMap { $0.isEmpty || $0 == "none" ? nil : $0 }
        languagePreference = c.decodeLenientSignedInt(forKey: .languagePreference)
    }

    private static let audioExts: Set<String> = ["m4a", "mp3", "opus", "ogg", "aac", "wav", "flac", "weba"]
    /// yt-dlp semantics: `"none"` is absent, a missing codec is unknown and counts as present,
    /// unless other evidence (no dimensions, an audio bitrate or an audio extension) says audio-only.
    public var hasVideo: Bool {
        if vcodec == "none" { return false }
        if vcodec == nil, height == nil, width == nil, abr != nil || Self.audioExts.contains(ext) { return false }
        return true
    }
    public var hasAudio: Bool { acodec != "none" }
    public var isStoryboard: Bool { ext == "mhtml" || formatNote == "storyboard" }
    /// Formats yt-dlp assembles from many requests (HLS, DASH segments, …); everything but plain http(s).
    public var isFragmented: Bool { !["https", "http"].contains(protocolName) }
    public var isH264: Bool { vcodec?.hasPrefix("avc1") ?? false }
    public var isHEVC: Bool { vcodec.map { $0.hasPrefix("hvc1") || $0.hasPrefix("hev1") } ?? false }
    public var isAAC: Bool { acodec?.hasPrefix("mp4a") ?? false }
    public var codecLabel: String {
        guard let v = vcodec, v != "none" else { return "" }
        if v.hasPrefix("avc1") { return "H.264" }
        if v.hasPrefix("vp09") || v.hasPrefix("vp9") { return "VP9" }
        if v.hasPrefix("av01") { return "AV1" }
        if v.hasPrefix("hvc1") || v.hasPrefix("hev1") { return "HEVC" }
        return v.uppercased()
    }
}

/// Reads `has_drm` (`true`, `false` or `"maybe"`) without failing on odd types.
struct DRMFlag {
    var protected = false
    var maybe = false
    init<K: CodingKey>(from c: KeyedDecodingContainer<K>, key: K) {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { protected = b; return }
        guard let s = (try? c.decodeIfPresent(String.self, forKey: key))?.lowercased() else { return }
        if s == "maybe" { maybe = true } else if s == "true" { protected = true }
    }
}

public struct MediaInfo: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var uploader: String?
    public var duration: Double?
    public var thumbnail: URL?
    public var webpageURL: URL?
    public var formats: [MediaFormat]
    public var subtitles: [String: [SubtitleTrack]]
    public var automaticCaptions: [String: [SubtitleTrack]]
    /// Formats decoded with `has_drm == true`, plus malformed ones whose `has_drm` was readable and true.
    public var protectedFormatCount: Int
    /// Formats that failed to decode and were skipped.
    public var droppedFormatCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, duration, thumbnail, webpageURL = "webpage_url", formats, subtitles
        case automaticCaptions = "automatic_captions"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        uploader = try c.decodeIfPresent(String.self, forKey: .uploader)
        duration = c.decodeLenientDouble(forKey: .duration)
        thumbnail = try? c.decodeIfPresent(URL.self, forKey: .thumbnail)
        webpageURL = try? c.decodeIfPresent(URL.self, forKey: .webpageURL)
        let lossy = (try? c.decodeIfPresent([LossyFormat].self, forKey: .formats)) ?? []
        formats = lossy.compactMap(\.value)
        droppedFormatCount = lossy.filter { $0.value == nil }.count
        protectedFormatCount = lossy.filter { $0.value?.hasDRM ?? $0.probedProtected }.count
        subtitles = Self.lenientTracks(c, .subtitles)
        automaticCaptions = Self.lenientTracks(c, .automaticCaptions)
    }

    private static func lenientTracks(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: [SubtitleTrack]] {
        guard let raw = try? c.decodeIfPresent([String: [LossyTrack]].self, forKey: key) else { return [:] }
        return raw.mapValues { $0.compactMap(\.value) }.filter { !$0.value.isEmpty }
    }

    /// Test helper: the same info with only the listed formats.
    init(copying other: MediaInfo, keeping ids: Set<String>) {
        self = other
        formats = other.formats.filter { ids.contains($0.formatID) }
    }
}

/// Skips a malformed format instead of failing the whole document.
private struct LossyFormat: Decodable {
    let value: MediaFormat?
    /// `has_drm` read on its own, so a DRM format that fails full decoding is still counted.
    let probedProtected: Bool

    private struct DRMProbe: Decodable {
        let protected: Bool
        enum CodingKeys: String, CodingKey { case hasDRM = "has_drm" }
        init(from decoder: any Decoder) throws {
            protected = DRMFlag(from: try decoder.container(keyedBy: CodingKeys.self), key: .hasDRM).protected
        }
    }

    init(from decoder: any Decoder) throws {
        probedProtected = (try? DRMProbe(from: decoder))?.protected ?? false
        value = try? MediaFormat(from: decoder)
    }
}

private struct LossyTrack: Decodable {
    let value: SubtitleTrack?
    init(from decoder: any Decoder) throws { value = try? SubtitleTrack(from: decoder) }
}

public struct PlaylistEntry: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    public var title: String?
    public var duration: Double?

    enum CodingKeys: String, CodingKey { case id, url, title, duration, webpageURL = "webpage_url" }

    /// Entries without an absolute http(s) address (a bare id, `file:`, or text such as `--exec=…` that yt-dlp would read
    /// as an option) fail to decode, so the playlist drops them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let candidates = [try? c.decodeIfPresent(URL.self, forKey: .url), try? c.decodeIfPresent(URL.self, forKey: .webpageURL)]
        guard let web = candidates.compactMap({ $0 }).first(where: MediaURL.isWebURL) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "no http(s) address")
        }
        url = web
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        duration = c.decodeLenientDouble(forKey: .duration)
    }
}

/// A playlist row's title, and whether it was guessed from the entry's link (shown as approximate).
public struct PlaylistEntryTitle: Sendable, Equatable {
    public var text: String
    public var isFromLink: Bool

    public init(text: String, isFromLink: Bool) {
        self.text = text
        self.isFromLink = isFromLink
    }
}

extension PlaylistEntry {
    /// The title for the checklist: the entry's own; else one guessed from its URL's last path segment
    /// ("premiere-weiss-i-believe" → "Premiere Weiss I Believe", marked `isFromLink`); else "Track N" (`index` is
    /// zero-based). Flat SoundCloud entries have no title; the per-entry lookup supplies the real one for the file.
    public func listTitle(at index: Int) -> PlaylistEntryTitle {
        if let own = knownTitle { return PlaylistEntryTitle(text: own, isFromLink: false) }
        if let guess = Self.slugTitle(url) { return PlaylistEntryTitle(text: guess, isFromLink: true) }
        return PlaylistEntryTitle(text: "Track \(index + 1)", isFromLink: false)
    }

    /// The entry's own title, else "Track N": never a guess from the link (used in notifications).
    public func knownTitle(at index: Int) -> String { knownTitle ?? "Track \(index + 1)" }

    private var knownTitle: String? {
        guard let own = title?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty else { return nil }
        return own
    }

    static func slugTitle(_ url: URL) -> String? {
        let segment = url.lastPathComponent        // already percent-decoded
        guard !segment.isEmpty, segment != "/", segment.contains(where: \.isLetter) else { return nil }
        if ["watch", "track", "tracks", "video", "videos", "index", "view", "embed"].contains(segment.lowercased()) { return nil }
        let words = segment.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
        let title = words.joined(separator: " ")
        return title.isEmpty ? nil : title
    }
}

public struct PlaylistInfo: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var entries: [PlaylistEntry]

    enum CodingKeys: String, CodingKey { case id, title, entries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        entries = (try? c.decode([LossyEntry].self, forKey: .entries))?.compactMap(\.value) ?? []
    }
}

private struct LossyEntry: Decodable {
    let value: PlaylistEntry?
    init(from decoder: any Decoder) throws { value = try? PlaylistEntry(from: decoder) }
}

public enum MediaProbeResult: Sendable, Equatable {
    case single(MediaInfo)
    case playlist(PlaylistInfo)

    private struct TypeProbe: Decodable { let _type: String? }

    public static func decode(_ data: Data) throws -> MediaProbeResult {
        let decoder = JSONDecoder()
        // yt-dlp (Python's json) prints a site's infinite or missing numbers as Infinity / NaN, which plain JSON rejects.
        // JSON5 accepts them; the lenient number decoding then drops them.
        decoder.allowsJSON5 = true
        if (try? decoder.decode(TypeProbe.self, from: data))?._type.map({ ["playlist", "multi_video"].contains($0) }) == true {
            return .playlist(try decoder.decode(PlaylistInfo.self, from: data))
        }
        return .single(try decoder.decode(MediaInfo.self, from: data))
    }
}
// MARK: Encoding (a restored download's plan)

extension SubtitleTrack: Encodable {
    /// yt-dlp's own shape, so `init(from:)` reads it back.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ext, forKey: .ext)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(streamProtocol, forKey: .streamProtocol)
    }
}

extension MediaFormat: Encodable {
    /// yt-dlp's own shape, so `init(from:)` reads it back: `has_drm` is `"maybe"` for a possibly protected format.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatID, forKey: .formatID)
        try c.encode(ext, forKey: .ext)
        try c.encode(protocolName, forKey: .protocolName)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(httpHeaders, forKey: .httpHeaders)
        try c.encodeIfPresent(vcodec, forKey: .vcodec)
        try c.encodeIfPresent(acodec, forKey: .acodec)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(fps, forKey: .fps)
        try c.encodeIfPresent(tbr, forKey: .tbr)
        try c.encodeIfPresent(abr, forKey: .abr)
        try c.encodeIfPresent(filesize, forKey: .filesize)
        try c.encodeIfPresent(filesizeApprox, forKey: .filesizeApprox)
        if possiblyProtected && !hasDRM {
            try c.encode("maybe", forKey: .hasDRM)
        } else {
            try c.encode(hasDRM, forKey: .hasDRM)
        }
        try c.encodeIfPresent(formatNote, forKey: .formatNote)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(languagePreference, forKey: .languagePreference)
    }
}
