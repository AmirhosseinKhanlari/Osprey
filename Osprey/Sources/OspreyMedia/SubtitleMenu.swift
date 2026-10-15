import Foundation

/// A subtitle the user picked: a language, from the uploaded subtitles or (`isAuto`) the automatic captions.
public struct SubtitleChoice: Sendable, Hashable {
    public var language: String
    public var isAuto: Bool

    public init(language: String, isAuto: Bool) {
        self.language = language
        self.isAuto = isAuto
    }
}

/// What the picker's Subtitles menu offers: the uploaded languages, and the automatic captions in their own submenu.
/// Both lists put English, the Mac's language and the current choice first, then the rest by code. Only languages with
/// a track ffmpeg can embed (SRT, WebVTT, ASS) are listed.
public struct SubtitleMenu: Sendable, Equatable {
    public let manual: [String]
    public let auto: [String]

    public var isEmpty: Bool { manual.isEmpty && auto.isEmpty }

    /// Uploaded subtitles put English, the Mac's language and the current choice first, then the rest by code.
    /// Automatic captions (often ~150 machine translations) put the video's original-language track first, then
    /// English, then the Mac's preferred languages in order, then the rest alphabetically by name.
    public init(info: MediaInfo, chosen: SubtitleChoice?, systemLanguage: String? = FormatCatalog.systemLanguageCode,
                preferredLanguages: [String] = Locale.preferredLanguages, locale: Locale = .current) {
        let float = ["en", systemLanguage, chosen?.language].compactMap { $0.map(Self.base) }
        manual = Self.ordered(Self.usableLanguages(info.subtitles), float: float)
        auto = Self.autoOrdered(Self.usableLanguages(info.automaticCaptions), preferred: preferredLanguages, locale: locale)
    }

    /// The languages whose name (or code) matches `query`: a word of the name, or the code, starting with it,
    /// ignoring case and accents. Order is kept; an empty query keeps everything.
    public func filtered(_ query: String, locale: Locale = .current) -> (manual: [String], auto: [String]) {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return (manual, auto) }
        func matches(_ code: String) -> Bool {
            if Self.fold(code).hasPrefix(q) { return true }
            let name = Self.fold(Self.name(code, locale: locale))
            return name.hasPrefix(q) || name.split(whereSeparator: { !$0.isLetter }).contains { $0.hasPrefix(q) }
        }
        return (manual.filter(matches), auto.filter(matches))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Original track(s) first, then English, then the preferred languages in order, then by localized name.
    private static func autoOrdered(_ codes: Set<String>, preferred: [String], locale: Locale) -> [String] {
        let isOriginal = { (code: String) in code.lowercased().hasSuffix("-orig") }
        let float = ["en"] + preferred.map(base)
        func rank(_ code: String) -> Int {
            if isOriginal(code) { return -1 }
            return float.firstIndex(of: base(code)) ?? float.count
        }
        return codes.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            let (na, nb) = (name(a, locale: locale), name(b, locale: locale))
            if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
            return a < b
        }
    }

    /// The choice when this video still offers it; otherwise nil (subtitles off). Never another language.
    public func resolve(_ choice: SubtitleChoice?) -> SubtitleChoice? {
        guard let choice else { return nil }
        return (choice.isAuto ? auto : manual).contains(choice.language) ? choice : nil
    }

    /// The track to embed for `choice`, from the list its auto mark names.
    public func track(for choice: SubtitleChoice, in info: MediaInfo) -> SubtitleTrack? {
        tracks(for: choice, in: info).first
    }

    /// Every track that can embed `choice`, best first (see `usableTracks`): the download tries them in turn.
    public func tracks(for choice: SubtitleChoice, in info: MediaInfo) -> [SubtitleTrack] {
        guard resolve(choice) != nil else { return [] }
        return Self.usableTracks((choice.isAuto ? info.automaticCaptions : info.subtitles)[choice.language] ?? [])
    }

    /// The chip's text: "Off", "German", or "English (auto)".
    public static func title(for choice: SubtitleChoice?, locale: Locale = .current) -> String {
        guard let choice else { return "Off" }
        return name(choice.language, locale: locale) + (choice.isAuto ? " (auto)" : "")
    }

    /// The language's name; YouTube's untranslated automatic captions ("en-orig") read "English (original)".
    public static func name(_ code: String, locale: Locale = .current) -> String {
        if code.lowercased().hasSuffix("-orig") {
            let language = String(code.dropLast(5))
            return (locale.localizedString(forIdentifier: language) ?? language) + " (original)"
        }
        return locale.localizedString(forIdentifier: code) ?? code
    }

    /// The best track ffmpeg can embed (see `usableTracks`).
    public static func usableTrack(_ tracks: [SubtitleTrack]) -> SubtitleTrack? {
        usableTracks(tracks).first
    }

    /// The tracks ffmpeg can embed, best first: plain SRT, WebVTT, then ASS files, then an HLS playlist of WebVTT
    /// segments (joined at download time). YouTube refuses direct auto-translated captions with HTTP 429 but serves
    /// the HLS ones, so that one is the last resort rather than left out.
    public static func usableTracks(_ tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        let direct = ["srt", "vtt", "ass"].flatMap { ext in
            tracks.filter { !$0.isHLS && $0.ext.lowercased() == ext }
        }
        return direct + tracks.filter { $0.isHLS && $0.ext.lowercased() == "vtt" }
    }

    private static func usableLanguages(_ tracks: [String: [SubtitleTrack]]) -> Set<String> {
        Set(tracks.keys.filter { !usableTracks(tracks[$0] ?? []).isEmpty })
    }

    private static func base(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// Languages whose base matches a floated one first (in the floated order), then the rest; by code within each.
    private static func ordered(_ codes: Set<String>, float: [String]) -> [String] {
        func rank(_ code: String) -> Int { float.firstIndex(of: base(code)) ?? float.count }
        return codes.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a < b
        }
    }
}
