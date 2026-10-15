import Foundation
import Testing
@testable import OspreyMedia

/// Multi-language YouTube videos list one audio format per language. By default the English track wins (whatever its
/// bitrate, original or dub), else the original track; a chosen language wins when the video has it.
@Suite struct AudioLanguageTests {
    private func audioID(_ plan: MediaPlan?) -> String? { plan?.parts.first { $0.role == .audio }?.format.formatID }

    /// The same video with every `format_note` stripped of "original"/"default": only language_preference tells.
    private func withoutOriginalNotes() throws -> MediaInfo {
        var text = String(decoding: try fixture("multi_language"), as: UTF8.self)
        text = text.replacingOccurrences(of: " original (default)", with: "")
        guard case .single(let info) = try MediaProbeResult.decode(Data(text.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        return info
    }

    @Test func decodesLanguageFields() throws {
        let i = try info("multi_language")
        let en = try #require(i.formats.first { $0.formatID == "140-0" })
        #expect(en.language == "en-US" && en.languagePreference == 10)
        #expect(i.formats.first { $0.formatID == "140-1" }?.languagePreference == -1)
        let old = try info("youtube_like")
        #expect(old.formats.allSatisfy { $0.language == nil && $0.languagePreference == nil })
    }

    @Test func lenientLanguagePreference() throws {
        let json = #"{"id":"x","formats":[{"format_id":"a","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","url":"https://m.example/a","language":"fr","language_preference":"5"},{"format_id":"b","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","url":"https://m.example/b","language_preference":"high"}]}"#
        guard case .single(let i) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected single"); return }
        #expect(i.formats.map(\.languagePreference) == [5, nil])
    }

    @Test func defaultPicksEnglishOverTheLouderDub() throws {
        let i = try info("multi_language")
        for compatible in [true, false] {
            let p1080 = try #require(FormatCatalog.videoOptions(for: i, compatible: compatible).first { $0.title == "1080p" })
            #expect(audioID(p1080.plan) == (compatible ? "140-0" : "251-0"))
        }
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(720), compatible: true)) == "140-0")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140-0")
        let audio = FormatCatalog.audioOptions(for: i)
        #expect(audio.first { $0.id == "a-m4a" }?.plan.parts.first?.format.formatID == "140-0")
        #expect(audio.first { $0.id == "a-mp3" }?.plan.parts.first?.format.formatID == "251-0")
    }

    @Test func choosingALanguagePicksIt() throws {
        let i = try info("multi_language")
        for code in ["de", "de-DE", "DE-de"] {
            let p = try #require(FormatCatalog.videoOptions(for: i, compatible: true, audioLanguage: code).first { $0.title == "1080p" })
            #expect(audioID(p.plan) == "140-1")
        }
        let opus = try #require(FormatCatalog.videoOptions(for: i, compatible: false, audioLanguage: "de").first { $0.title == "1080p" })
        #expect(audioID(opus.plan) == "251-1")
        let es = FormatCatalog.audioOptions(for: i, audioLanguage: "es")
        #expect(es.first { $0.id == "a-m4a" }?.plan.parts.first?.format.formatID == "140-2")
        #expect(es.first { $0.id == "a-mp3" }?.plan.parts.first?.format.formatID == "140-2")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(1080), compatible: true, audioLanguage: "es")) == "140-2")
        // The size estimate follows the chosen track.
        let en = try #require(FormatCatalog.videoOptions(for: i, compatible: true).first { $0.title == "1080p" })
        let de = try #require(FormatCatalog.videoOptions(for: i, compatible: true, audioLanguage: "de").first { $0.title == "1080p" })
        #expect(en.estimatedBytes == 339_700_000 && de.estimatedBytes == 342_000_000)
    }

    @Test func audioLanguagesAreOriginalThenSystemThenAlphabetical() throws {
        let i = try info("multi_language")
        let none = FormatCatalog.audioLanguages(for: i, systemLanguage: nil)
        #expect(none.map(\.code) == ["en-US", "de-DE", "es-US"])
        #expect(none.map(\.isOriginal) == [true, false, false])
        #expect(none.map(\.isDefault) == [true, false, false])
        #expect(none.allSatisfy { !$0.name.isEmpty })
        #expect(FormatCatalog.audioLanguages(for: i, systemLanguage: "es").map(\.code) == ["en-US", "es-US", "de-DE"])
        #expect(FormatCatalog.audioLanguages(for: i, systemLanguage: "en").map(\.code) == ["en-US", "de-DE", "es-US"])
    }

    @Test func theHighestLanguagePreferenceMarksTheOriginal() throws {
        let i = try withoutOriginalNotes()
        let languages = FormatCatalog.audioLanguages(for: i, systemLanguage: "de")
        #expect(languages.first?.code == "en-US" && languages.first?.isOriginal == true)
        #expect(languages.map(\.isDefault) == [false, false, false])
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true,
                                           audioLanguage: FormatCatalog.originalAudioLanguage)) == "140-0")
    }

    @Test func defaultPicksEnglishEvenWhenItIsADub() throws {
        let i = try info("german_original")
        #expect(FormatCatalog.audioLanguages(for: i, systemLanguage: nil).map(\.code) == ["de-DE", "en-US", "es-US"])
        #expect(FormatCatalog.audioLanguages(for: i, systemLanguage: nil).map(\.isOriginal) == [true, false, false])
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140-1")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(720), compatible: false)) == "140-1")
        #expect(FormatCatalog.audioOptions(for: i).first { $0.id == "a-m4a" }?.plan.parts.first?.format.formatID == "140-1")
        // Asking for the original, or for German, gives German.
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true,
                                           audioLanguage: FormatCatalog.originalAudioLanguage)) == "140-0")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true, audioLanguage: "de")) == "140-0")
    }

    @Test func withoutEnglishTheOriginalWins() throws {
        var text = String(decoding: try fixture("german_original"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"en-US\"", with: "\"fr-FR\"")
        guard case .single(let i) = try MediaProbeResult.decode(Data(text.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140-0")
    }

    @Test func withoutEnglishOrAnOriginalTheUsualRankingDecides() throws {
        var text = String(decoding: try fixture("german_original"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"en-US\"", with: "\"fr-FR\"")
            .replacingOccurrences(of: " original (default)", with: "")
            .replacingOccurrences(of: "\"language_preference\": 10", with: "\"language_preference\": -1")
        guard case .single(let i) = try MediaProbeResult.decode(Data(text.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        #expect(FormatCatalog.audioLanguages(for: i).allSatisfy { !$0.isOriginal })
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140-0")      // highest bitrate
    }

    @Test func amongSeveralEnglishTracksTheOriginalThenThePreferenceWins() throws {
        var text = String(decoding: try fixture("german_original"), as: UTF8.self)
        // German becomes a British English original with the lowest bitrate; another English dub stays.
        text = text.replacingOccurrences(of: "\"de-DE\"", with: "\"en-GB\"").replacingOccurrences(of: "\"abr\": 160", with: "\"abr\": 64")
        guard case .single(let i) = try MediaProbeResult.decode(Data(text.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140-0")
        var notes = text.replacingOccurrences(of: " original (default)", with: "")
        notes = notes.replacingOccurrences(of: "\"language_preference\": 10", with: "\"language_preference\": 5")
        guard case .single(let j) = try MediaProbeResult.decode(Data(notes.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        #expect(audioID(FormatCatalog.plan(for: j, cap: .best, compatible: true)) == "140-0")      // higher preference
    }

    @Test func playlistFallsBackToTheOriginalWhenTheLanguageIsMissing() throws {
        let i = try info("multi_language")
        func plan(_ cap: QualityCap, _ language: String?) -> MediaPlan? {
            try? FormatCatalog.playlistPlan(for: i, cap: cap, compatible: true, hasFFmpeg: true, audioLanguage: language).get()
        }
        #expect(audioID(plan(.maxHeight(1080), "fr")) == "140-0")
        #expect(audioID(plan(.maxHeight(1080), "de")) == "140-1")
        #expect(audioID(plan(.audioM4A, "fr")) == "140-0")
        #expect(audioID(plan(.audioMP3, "de")) == "251-1")
        #expect(audioID(plan(.best, nil)) == "140-0")
        let german = try info("german_original")
        func dePlan(_ language: String?) -> MediaPlan? {
            try? FormatCatalog.playlistPlan(for: german, cap: .maxHeight(1080), compatible: true, hasFFmpeg: true, audioLanguage: language).get()
        }
        #expect(audioID(dePlan(nil)) == "140-1")           // English by default
        #expect(audioID(dePlan("en")) == "140-1")
        #expect(audioID(dePlan("fr")) == "140-0")          // no French: the original (German)
        #expect(audioID(dePlan(FormatCatalog.originalAudioLanguage)) == "140-0")
    }

    @Test func videosWithoutLanguagesBehaveAsBefore() throws {
        let i = try info("youtube_like")
        #expect(FormatCatalog.audioLanguages(for: i).isEmpty)
        for compatible in [true, false] {
            #expect(FormatCatalog.videoOptions(for: i, compatible: compatible, audioLanguage: "de")
                    == FormatCatalog.videoOptions(for: i, compatible: compatible))
        }
        #expect(FormatCatalog.audioOptions(for: i, audioLanguage: "de") == FormatCatalog.audioOptions(for: i))
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(1080), compatible: true)) == "140")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(1080), compatible: false)) == "251")
    }

    /// Found live (Big Buck Bunny): every audio format has language_preference -1 except an HLS audio format ("233",
    /// no codec, no preference). Preferences only order tracks within a language, so it must not win.
    @Test func aPreferenceWithoutALanguageChangesNothing() throws {
        let json = #"{"id":"b","title":"B","duration":60,"formats":[{"format_id":"233","ext":"mp4","protocol":"m3u8_native","vcodec":"none","url":"https://m.example/233"},{"format_id":"140","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":129,"filesize":1000,"language_preference":-1,"url":"https://m.example/140"},{"format_id":"251","ext":"webm","protocol":"https","vcodec":"none","acodec":"opus","abr":128,"filesize":1000,"language_preference":-1,"url":"https://m.example/251"},{"format_id":"298","ext":"mp4","protocol":"https","vcodec":"avc1.4d4020","acodec":"none","height":720,"filesize":5000,"url":"https://m.example/298"}]}"#
        guard case .single(let i) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected single"); return }
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140")
        #expect(FormatCatalog.audioOptions(for: i).map(\.id) == ["a-m4a", "a-mp3"])
    }

    /// Found live (a MrBeast video): each dub also has an HLS audio format ("233-2", language "de", no codec, no
    /// language_preference). Choosing German must still give the German M4A, not the HLS one.
    @Test func aTrackWithoutAPreferenceDoesNotBeatOneWithIt() throws {
        let json = #"{"id":"m","title":"M","duration":60,"formats":[{"format_id":"233-2","ext":"mp4","protocol":"m3u8_native","vcodec":"none","language":"de","format_note":"Deutsch - dubbed","url":"https://m.example/233-2"},{"format_id":"140-5","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":129,"filesize":1000,"language":"de","language_preference":-1,"format_note":"German, medium","url":"https://m.example/140-5"},{"format_id":"140-23","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":129,"filesize":1000,"language":"en-US","language_preference":10,"format_note":"English (US) original (default), medium","url":"https://m.example/140-23"},{"format_id":"160","ext":"mp4","protocol":"https","vcodec":"avc1.4d400c","acodec":"none","height":144,"filesize":5000,"url":"https://m.example/160"}]}"#
        guard case .single(let i) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected single"); return }
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true, audioLanguage: "de")) == "140-5")
        #expect(FormatCatalog.audioOptions(for: i, audioLanguage: "de").first?.plan.parts.first?.format.formatID == "140-5")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .best, compatible: true)) == "140-23")
    }

    /// Fix round 2 (I8): only some tracks name a language. French direct audio at 192k and 64k (no preference) and an
    /// unlabelled 48k HLS track: the 192k French track must win everywhere.
    @Test func partlyLabelledTracksRankByQuality() throws {
        let i = try info("partly_labelled")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(1080), compatible: true)) == "fr-192")
        #expect(audioID(FormatCatalog.plan(for: i, cap: .maxHeight(1080), compatible: false)) == "fr-192")
        let audio = FormatCatalog.audioOptions(for: i)
        #expect(audio.first { $0.id == "a-m4a" }?.plan.parts.first?.format.formatID == "fr-192")
        #expect(audio.first { $0.id == "a-mp3" }?.plan.parts.first?.format.formatID == "fr-192")
    }

    /// Preferences only order tracks of one language: across two dubs in the same tier the bitrate decides.
    @Test func preferencesDoNotCrossLanguages() throws {
        let json = #"{"id":"p","title":"P","duration":60,"formats":[{"format_id":"fr","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":64,"language":"fr","language_preference":5,"url":"https://m.example/fr"},{"format_id":"it","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":192,"language":"it","url":"https://m.example/it"},{"format_id":"es","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":160,"language":"es","language_preference":5,"url":"https://m.example/es"}]}"#
        guard case .single(let i) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected single"); return }
        // No English and no single original (fr and es tie at 5): the usual ranking picks the 192k track.
        #expect(FormatCatalog.audioOptions(for: i).first { $0.id == "a-m4a" }?.plan.parts.first?.format.formatID == "it")
    }
}
