import Foundation

public enum FormatCatalog {
    static func usable(_ info: MediaInfo) -> [MediaFormat] {
        info.formats.filter {
            !$0.hasDRM && !$0.isStoryboard && ($0.hasVideo || $0.hasAudio)
                && ($0.url != nil || $0.isFragmented)     // direct downloads need a URL; fragmented ones go by format_id
        }
    }

    public static func isFullyProtected(_ info: MediaInfo) -> Bool {
        info.protectedFormatCount > 0 && usable(info).isEmpty
    }

    /// True when some formats were withheld for DRM (the UI says "Some qualities are protected").
    public static func hasProtectedFormats(_ info: MediaInfo) -> Bool { info.protectedFormatCount > 0 }

    /// One option per video height, highest first; formats without a height share one trailing option.
    /// - audioLanguage: the audio track to pair with video-only formats: a language code, `originalAudioLanguage`, or nil for
    ///   the default (English, else the original; see `LanguageChoice`).
    public static func videoOptions(for info: MediaInfo, compatible: Bool, audioLanguage: String? = nil) -> [QualityOption] {
        let formats = usable(info)
        let languages = LanguageChoice(info: info, preferred: audioLanguage)
        let heights = Set(formats.filter(\.hasVideo).compactMap(\.height)).sorted(by: >)
        var groups: [(height: Int?, video: MediaFormat)] = heights.compactMap { h in
            bestVideo(in: formats, height: h, compatible: compatible).map { (h, $0) }
        }
        if let unknown = bestVideo(in: formats, height: nil, compatible: compatible) { groups.append((nil, unknown)) }
        return groups.map { height, video in
            let audio = video.hasAudio ? nil : bestAudio(in: formats, compatible: compatible, preferAAC: video.isH264, languages: languages)
            let parts = audio.map { [MediaPart(format: video, role: .video), MediaPart(format: $0, role: .audio)] }
                ?? [MediaPart(format: video, role: video.hasAudio ? .combined : .video)]
            let container = containerFor(video: video, audio: audio)
            let plan = MediaPlan(parts: parts, container: container, convertToMP3: false, subtitle: nil, subtitleLanguage: nil)
            let (bytes, approx) = estimate(parts.map(\.format), duration: info.duration)
            // A site can report any fps; only a plausible one becomes a suffix ("1080p60").
            let fpsSuffix = video.fps.flatMap { $0 > 30 && $0 < 1000 ? Int(exactly: $0.rounded()).map(String.init) : nil } ?? ""
            let detail = [video.codecLabel, container.rawValue.uppercased()].filter { !$0.isEmpty }.joined(separator: " · ")
            let title = height.map { "\($0)p\(fpsSuffix)" } ?? (video.formatNote ?? "Original")
            return QualityOption(id: "v\(height.map(String.init) ?? "nh")\(compatible ? "c" : "b")", title: title, detail: detail,
                                 estimatedBytes: bytes, estimateIsApproximate: approx, plan: plan)
        }
    }

    /// M4A (original AAC) and MP3, both from the audio track in `audioLanguage` (as in `videoOptions`).
    public static func audioOptions(for info: MediaInfo, audioLanguage: String? = nil) -> [QualityOption] {
        let languages = LanguageChoice(info: info, preferred: audioLanguage)
        let formats = languages.bestTier(usable(info).filter { $0.hasAudio && !$0.hasVideo })
        var options: [QualityOption] = []
        if let aac = formats.filter(\.isAAC).max(by: audioRank) {
            let (bytes, approx) = estimate([aac], duration: info.duration)
            options.append(QualityOption(id: "a-m4a", title: "Audio · M4A", detail: "Original AAC", estimatedBytes: bytes,
                                         estimateIsApproximate: approx,
                                         plan: MediaPlan(parts: [MediaPart(format: aac, role: .audio)], container: .m4a,
                                                         convertToMP3: false, subtitle: nil, subtitleLanguage: nil)))
        }
        if let best = formats.max(by: audioRank) {
            // Converted size is fixed by the 192 kbit/s encode, not by the source stream.
            let bytes = info.duration.flatMap { MediaText.byteCount($0 * 192_000 / 8) }
            options.append(QualityOption(id: "a-mp3", title: "Audio · MP3", detail: "Converted", estimatedBytes: bytes,
                                         estimateIsApproximate: true,          // MP3 size depends on the encoder
                                         plan: MediaPlan(parts: [MediaPart(format: best, role: .audio)], container: .mp3,
                                                         convertToMP3: true, subtitle: nil, subtitleLanguage: nil)))
        }
        return options
    }

    public static func plan(for info: MediaInfo, cap: QualityCap, compatible: Bool, audioLanguage: String? = nil) -> MediaPlan? {
        let audio = { audioOptions(for: info, audioLanguage: audioLanguage) }
        switch cap {
        case .audioM4A: return audio().first { $0.id == "a-m4a" }?.plan   // never silently convert
        case .audioMP3: return audio().first { $0.id == "a-mp3" }?.plan
        case .best:
            return videoOptions(for: info, compatible: compatible, audioLanguage: audioLanguage)
                .first?.plan ?? audio().first?.plan
        case .maxHeight(let limit):
            let options = videoOptions(for: info, compatible: compatible, audioLanguage: audioLanguage)
            let sized = options.filter { height(of: $0) > 0 }
            let fitting = sized.first { height(of: $0) <= limit }
            return (fitting ?? sized.last ?? options.last)?.plan ?? audio().first?.plan
        }
    }

    /// What a playlist entry downloads at `cap`, decided when it's added. A video cap never silently becomes audio
    /// (that happens when the video is protected), and a plan that needs ffmpeg fails when it's missing.
    /// - audioLanguage: the playlist's language choice; an entry without that language gets its original track.
    public static func playlistPlan(for info: MediaInfo, cap: QualityCap, compatible: Bool, hasFFmpeg: Bool,
                                    audioLanguage: String? = nil) -> Result<MediaPlan, PlaylistEntryProblem> {
        if isFullyProtected(info) { return .failure(.protected) }
        guard let plan = plan(for: info, cap: cap, compatible: compatible, audioLanguage: audioLanguage) else {
            return .failure(hasProtectedFormats(info) ? .protected : .noMatchingQuality)
        }
        let wantsVideo: Bool = switch cap {
        case .best, .maxHeight: true
        case .audioM4A, .audioMP3: false
        }
        // No video part: protected video must not silently become audio; an audio-only source (SoundCloud) has
        // no video to protect, so it gets its audio.
        if wantsVideo, !plan.parts.contains(where: { $0.role != .audio }), videoIsProtected(info) {
            return .failure(.protected)
        }
        if plan.needsFFmpeg, !hasFFmpeg { return .failure(.needsFFmpeg) }
        return .success(plan)
    }

    /// Some video format is DRM-protected, counting malformed protected formats dropped while decoding.
    static func videoIsProtected(_ info: MediaInfo) -> Bool {
        info.formats.contains { $0.hasVideo && $0.hasDRM } || info.protectedFormatCount > info.formats.filter(\.hasDRM).count
    }

    /// YouTube marks its quieter, dynamic-range-compressed audio with a `-drc` id suffix and "DRC" in the note.
    static func isDRC(_ format: MediaFormat) -> Bool {
        format.formatID.lowercased().hasSuffix("-drc") || format.formatNote?.range(of: "drc", options: .caseInsensitive) != nil
    }

    private static func height(of option: QualityOption) -> Int {
        option.plan.parts.first { $0.role != .audio }?.format.height ?? 0
    }

    /// Orders formats worst to best. Ties fall through: higher rank, direct over fragmented,
    /// unmarked over possibly-DRM, then bitrate.
    private static func isWorse(_ a: MediaFormat, _ b: MediaFormat) -> Bool {
        if a.isFragmented != b.isFragmented { return a.isFragmented }
        if a.possiblyProtected != b.possiblyProtected { return a.possiblyProtected }
        return (a.tbr ?? 0) < (b.tbr ?? 0)
    }

    private static func bestVideo(in formats: [MediaFormat], height: Int?, compatible: Bool) -> MediaFormat? {
        let candidates = formats.filter { $0.hasVideo && $0.height == height }
        let byQuality: (MediaFormat, MediaFormat) -> Bool = { a, b in
            let fa = a.fps ?? 30, fb = b.fps ?? 30                     // unknown fps compares as 30
            if fa != fb { return fa < fb }
            if a.hasAudio != b.hasAudio { return a.hasAudio }        // prefer video-only (paired with the best audio)
            return isWorse(a, b)
        }
        if compatible, let h264 = candidates.filter(\.isH264).max(by: byQuality) { return h264 }
        return candidates.max(by: byQuality)
    }

    /// Audio rank: a plain stream over its DRC (dynamic range compressed) twin; then abr, else tbr; then direct,
    /// unmarked, tbr, and finally file size.
    private static func audioRank(_ a: MediaFormat, _ b: MediaFormat) -> Bool {
        if isDRC(a) != isDRC(b) { return isDRC(a) }
        let qa = a.abr ?? a.tbr ?? 0, qb = b.abr ?? b.tbr ?? 0
        if qa != qb { return qa < qb }
        if a.isFragmented != b.isFragmented || a.possiblyProtected != b.possiblyProtected || (a.tbr ?? 0) != (b.tbr ?? 0) {
            return isWorse(a, b)
        }
        return (a.filesize ?? a.filesizeApprox ?? 0) < (b.filesize ?? b.filesizeApprox ?? 0)
    }

    /// The language comes first (see `LanguageChoice`), then the codec and quality: a bitrate never outranks the language.
    private static func bestAudio(in formats: [MediaFormat], compatible: Bool, preferAAC: Bool,
                                  languages: LanguageChoice) -> MediaFormat? {
        let audio = languages.bestTier(formats.filter { $0.hasAudio && !$0.hasVideo })
        // AAC only when building a QuickTime-compatible MP4 (H.264 video); otherwise the best audio overall.
        if compatible && preferAAC, let aac = audio.filter(\.isAAC).max(by: audioRank) { return aac }
        return audio.max(by: audioRank)
    }

    private static func containerFor(video: MediaFormat, audio: MediaFormat?) -> Container {
        guard let audio else {
            switch video.ext {
            case "mp4", "m4v": return .mp4
            case "webm": return .webm
            default: return .mkv
            }
        }
        return video.isH264 && audio.isAAC ? .mp4 : .mkv
    }

    /// Exact sizes when every part reports `filesize`; else `filesize_approx`, else tbr × duration.
    /// Nil when a size is missing or the numbers (which come from the site) don't fit in an Int64.
    static func estimate(_ formats: [MediaFormat], duration: Double?) -> (Int64?, Bool) {
        var total: Int64 = 0
        var approx = false
        for f in formats {
            let size: Int64?
            if let exact = f.filesize {
                size = exact
            } else {
                approx = true
                if let approximate = f.filesizeApprox {
                    size = approximate
                } else if let tbr = f.tbr ?? f.abr, let duration {
                    size = MediaText.byteCount(tbr * 1000 / 8 * duration)
                } else {
                    size = nil
                }
            }
            guard let size, let sum = MediaText.sum(total, size) else { return (nil, true) }
            total = sum
        }
        return (total, approx)
    }

    // MARK: Audio languages

    /// The Mac's language ("en"); the language menu lists it right after the original.
    public static var systemLanguageCode: String? { Locale.current.language.languageCode?.identifier }

    /// An `audioLanguage` that asks for the video's original track, whatever its language.
    public static let originalAudioLanguage = "original"
    /// What an unset `audioLanguage` means: English (any region), else the original track.
    public static let defaultAudioLanguage = "en"

    /// The audio languages a video offers, deduplicated: the original first, then the system language, then by name.
    /// Empty when no audio format names a language.
    public static func audioLanguages(for info: MediaInfo, systemLanguage: String? = systemLanguageCode) -> [AudioLanguage] {
        let audio = usable(info).filter { $0.hasAudio && !$0.hasVideo }
        var codes: [String] = []                                   // first spelling seen, in format order
        var seen = Set<String>()
        for format in audio {
            guard let code = format.language, seen.insert(code.lowercased()).inserted else { continue }
            codes.append(code)
        }
        let originals = LanguageChoice.originals(in: audio)
        let names = codes.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        let languages = codes.enumerated().map { index, code in
            // Two regional variants of one language would read the same: spell those out ("English (United Kingdom)").
            let shared = names.filter { $0 == names[index] }.count > 1
            let name = shared ? (Locale.current.localizedString(forIdentifier: code) ?? code) : names[index]
            let isDefault = audio.contains { $0.language?.lowercased() == code.lowercased()
                && $0.formatNote?.range(of: "default", options: .caseInsensitive) != nil }
            return AudioLanguage(code: code, name: name, isOriginal: originals.contains(code.lowercased()), isDefault: isDefault)
        }
        let system = systemLanguage.map(LanguageChoice.primary)
        return languages.sorted { a, b in
            if a.isOriginal != b.isOriginal { return a.isOriginal }
            let sa = LanguageChoice.primary(a.code) == system, sb = LanguageChoice.primary(b.code) == system
            if sa != sb { return sa }
            let byName = a.name.localizedStandardCompare(b.name)
            return byName == .orderedSame ? a.code < b.code : byName == .orderedAscending
        }
    }
}

/// One audio language a video offers.
public struct AudioLanguage: Sendable, Equatable, Identifiable {
    /// yt-dlp's code, as the site gave it ("en-US").
    public var code: String
    /// The language's name in the user's language ("English").
    public var name: String
    /// The video's own language: "original" in the format note, or the highest `language_preference`.
    public var isOriginal: Bool
    /// The site's default track ("default" in the format note).
    public var isDefault: Bool
    public var id: String { code }
}

/// How audio formats are ranked by language. Higher wins; formats of equal rank fall back to the usual ranking (DRC,
/// bitrate, …), and formats without a language all rank alike, so videos with no language information are unaffected.
/// - A language code ("de", "es-US"): that language (exact code over the same base language), else the original track.
/// - `originalAudioLanguage`: the original track.
/// - nil: English (any region), else the original track.
/// Within one language, the original track comes first, then the higher `language_preference`.
struct LanguageChoice {
    /// Lowercased; nil only for "original".
    let wanted: String?
    let originals: Set<String>

    init(info: MediaInfo, preferred: String?) {
        let choice = (preferred ?? FormatCatalog.defaultAudioLanguage).lowercased()
        wanted = choice == FormatCatalog.originalAudioLanguage ? nil : choice
        originals = Self.originals(in: info.formats.filter { $0.hasAudio && !$0.hasVideo })
    }

    /// "en-US" → "en"; "pt_BR" → "pt".
    static func primary(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code.lowercased()))
    }

    private static func notesOriginal(_ format: MediaFormat) -> Bool {
        format.formatNote?.range(of: "original", options: .caseInsensitive) != nil
    }

    /// Lowercased codes of the original track: noted "original", or the one language with the highest preference.
    static func originals(in audio: [MediaFormat]) -> Set<String> {
        var result = Set(audio.filter(notesOriginal).compactMap { $0.language?.lowercased() })
        var best: [String: Int] = [:]
        for format in audio {
            guard let code = format.language?.lowercased(), let preference = format.languagePreference else { continue }
            best[code] = max(best[code] ?? .min, preference)
        }
        if let top = best.values.max() {
            let leaders = best.filter { $0.value == top }.map(\.key)
            if leaders.count == 1 { result.insert(leaders[0]) }
        }
        return result
    }

    func isOriginal(_ format: MediaFormat) -> Bool {
        Self.notesOriginal(format) || format.language.map { originals.contains($0.lowercased()) } == true
    }

    /// The language tier: the wanted language (exact code over the same base language), else the original track.
    /// Formats of equal rank are ordered by the usual quality ranking; `language_preference` never crosses languages.
    func rank(_ format: MediaFormat) -> Int {
        let original = isOriginal(format)
        var tier = original ? 3 : 0
        if let wanted, let code = format.language?.lowercased() {
            if code == wanted { tier = 6 } else if Self.primary(code) == Self.primary(wanted) { tier = 5 }
        }
        return tier * 10 + (original ? 5 : 0)
    }

    /// The formats in the best-ranked tier (all of them when none names a language). Within each language of that tier,
    /// only the tracks with that language's highest `language_preference` stay; a track without a preference counts as
    /// lowest only when another track of its language has one. Across languages, and for tracks with no language, the
    /// usual quality ranking (DRC, direct, bitrate) decides.
    func bestTier(_ formats: [MediaFormat]) -> [MediaFormat] {
        guard let top = formats.map(rank).max() else { return [] }
        let tier = formats.filter { rank($0) == top }
        var bestPreference: [String: Int] = [:]
        for format in tier {
            guard let code = format.language?.lowercased(), let preference = format.languagePreference else { continue }
            bestPreference[code] = max(bestPreference[code] ?? .min, preference)
        }
        return tier.filter { format in
            guard let code = format.language?.lowercased(), let best = bestPreference[code] else { return true }
            return format.languagePreference == best
        }
    }
}
