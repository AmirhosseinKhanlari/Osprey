import Foundation
import Testing
@testable import OspreyMedia

@Suite struct SubtitleMenuTests {
    /// Manual subtitles in `manual`, automatic captions in `auto`; `bad` languages only have an unusable format.
    static func info(manual: [String], auto: [String], bad: [String] = []) throws -> MediaInfo {
        func tracks(_ codes: [String], ext: String) -> String {
            codes.map { "\"\($0)\":[{\"ext\":\"\(ext)\",\"url\":\"https://s.example/\($0).\(ext)\"}]" }.joined(separator: ",")
        }
        let subs = [tracks(manual, ext: "vtt"), tracks(bad, ext: "json3")].filter { !$0.isEmpty }.joined(separator: ",")
        return try infoJSON([fmt("v", #""vcodec":"avc1","acodec":"mp4a.40.2","height":360"#)],
                            extra: ",\"subtitles\":{\(subs)},\"automatic_captions\":{\(tracks(auto, ext: "srt"))}")
    }

    @Test func englishSystemAndChosenFloatThenTheRestByCode() throws {
        let i = try Self.info(manual: ["ar", "de", "en-US", "es", "fr", "ja", "en-GB"], auto: [])
        let menu = SubtitleMenu(info: i, chosen: SubtitleChoice(language: "ja", isAuto: false), systemLanguage: "fr")
        #expect(menu.manual == ["en-GB", "en-US", "fr", "ja", "ar", "de", "es"])
    }

    @Test func autoCaptionsGoInTheirOwnListWithTheSameOrder() throws {
        let i = try Self.info(manual: ["de"], auto: ["zu", "ko", "en", "aa", "de"])
        let menu = SubtitleMenu(info: i, chosen: nil, systemLanguage: "ko", preferredLanguages: ["ko"], locale: Self.en)
        #expect(menu.manual == ["de"])
        #expect(menu.auto == ["en", "ko", "aa", "de", "zu"])
        #expect(!menu.isEmpty)
    }

    static let en = Locale(identifier: "en_US")

    /// Automatic captions: the video's original-language track first, then English, then the Mac's preferred
    /// languages in their order, then the rest alphabetically by name (not by code).
    @Test func autoCaptionsOriginalFirstThenEnglishThenPreferredThenByName() throws {
        let i = try Self.info(manual: [], auto: ["de", "ja", "fr", "en", "es", "fr-orig", "el", "zh-Hant", "sv"])
        let menu = SubtitleMenu(info: i, chosen: SubtitleChoice(language: "sv", isAuto: true), systemLanguage: "ja",
                                preferredLanguages: ["ja-JP", "es"], locale: Self.en)
        // fr-orig, English, Japanese, Spanish, then by name: Chinese (Traditional), French, German, Greek, Swedish.
        #expect(menu.auto == ["fr-orig", "en", "ja", "es", "zh-Hant", "fr", "de", "el", "sv"])
    }

    @Test func searchMatchesNameOrCodeInBothSections() throws {
        let i = try Self.info(manual: ["en", "fr", "de"], auto: ["fr", "fr-orig", "fy", "de", "en"])
        let menu = SubtitleMenu(info: i, chosen: nil, systemLanguage: nil, preferredLanguages: [], locale: Self.en)
        let fr = menu.filtered("fr", locale: Self.en)
        #expect(fr.manual == ["fr"])
        #expect(fr.auto == ["fr-orig", "fr", "fy"])                // French (original), French, Western Frisian
        #expect(menu.filtered("  GER ", locale: Self.en).auto == ["de"])
        #expect(menu.filtered("ENG", locale: Self.en).manual == ["en"])
        #expect(menu.filtered("de", locale: Self.en).manual == ["de"])   // by code
        #expect(menu.filtered("", locale: Self.en) == (manual: menu.manual, auto: menu.auto))
        #expect(menu.filtered("xyz", locale: Self.en).auto.isEmpty)
    }

    @Test func unusableFormatsAreLeftOut() throws {
        let i = try Self.info(manual: ["en"], auto: [], bad: ["xx"])
        #expect(SubtitleMenu(info: i, chosen: nil, systemLanguage: nil).manual == ["en"])
        #expect(SubtitleMenu(info: try Self.info(manual: [], auto: []), chosen: nil, systemLanguage: nil).isEmpty)
    }

    @Test func aVanishedChoiceTurnsSubtitlesOffNeverAnotherLanguage() throws {
        let i = try Self.info(manual: ["en", "de"], auto: ["fr"])
        let menu = SubtitleMenu(info: i, chosen: nil, systemLanguage: nil)
        #expect(menu.resolve(SubtitleChoice(language: "de", isAuto: false)) == SubtitleChoice(language: "de", isAuto: false))
        #expect(menu.resolve(SubtitleChoice(language: "fr", isAuto: true)) == SubtitleChoice(language: "fr", isAuto: true))
        #expect(menu.resolve(SubtitleChoice(language: "ja", isAuto: false)) == nil)       // gone: Off
        #expect(menu.resolve(SubtitleChoice(language: "fr", isAuto: false)) == nil)       // only an auto track: Off
        #expect(menu.resolve(nil) == nil)
    }

    @Test func trackFollowsTheAutoMark() throws {
        let i = try Self.info(manual: ["en"], auto: ["en"])
        let menu = SubtitleMenu(info: i, chosen: nil, systemLanguage: nil)
        #expect(menu.track(for: SubtitleChoice(language: "en", isAuto: false), in: i)?.ext == "vtt")
        #expect(menu.track(for: SubtitleChoice(language: "en", isAuto: true), in: i)?.ext == "srt")
        #expect(menu.track(for: SubtitleChoice(language: "xx", isAuto: true), in: i) == nil)
    }

    @Test func chipTitleMarksAutoTracks() {
        #expect(SubtitleMenu.title(for: nil) == "Off")
        let auto = SubtitleMenu.title(for: SubtitleChoice(language: "en", isAuto: true), locale: Locale(identifier: "en_US"))
        #expect(auto == "English (auto)")
        #expect(SubtitleMenu.title(for: SubtitleChoice(language: "de", isAuto: false), locale: Locale(identifier: "en_US")) == "German")
    }

    // YouTube's untranslated automatic captions are "<lang>-orig".
    @Test func originalAutoCaptionsHaveAReadableName() {
        #expect(SubtitleMenu.name("en-orig", locale: Locale(identifier: "en_US")) == "English (original)")
        #expect(SubtitleMenu.title(for: SubtitleChoice(language: "en-orig", isAuto: true), locale: Locale(identifier: "en_US"))
                == "English (original) (auto)")
    }
}
