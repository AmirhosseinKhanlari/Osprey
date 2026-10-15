import Foundation
import Testing
@testable import OspreyMedia

@Suite struct PlaylistMessagesTests {
    let failures = [PlaylistFailure(title: "WING IT!", reason: .protected),
                    PlaylistFailure(title: "Removed one", reason: .unreadable)]

    @Test func namedWordingListsTitlesAndReasons() {
        let text = PlaylistFailure.notificationText(playlist: "Open Movies", failures: failures, isPrivate: false)
        #expect(text.title == "2 videos from “Open Movies” weren’t added")
        #expect(text.body == "WING IT! — protected (DRM)\nRemoved one — couldn’t be read")
        let one = PlaylistFailure.notificationText(playlist: "P", failures: [failures[0]], isPrivate: false)
        #expect(one.title == "1 video from “P” wasn’t added")
    }

    @Test func namedWordingTruncatesAfterThree() {
        let many = (1...5).map { PlaylistFailure(title: "V\($0)", reason: .needsFFmpeg) }
        let text = PlaylistFailure.notificationText(playlist: "P", failures: many, isPrivate: false)
        #expect(text.body == "V1 — needs ffmpeg\nV2 — needs ffmpeg\nV3 — needs ffmpeg\n…and 2 more")
    }

    @Test func privateWordingNamesNothing() {
        let text = PlaylistFailure.notificationText(playlist: "Secret list", failures: failures, isPrivate: true)
        #expect(text.title == "Some playlist videos weren’t added")
        #expect(text.body == "2 videos from a private window couldn’t be added. 1 is protected (DRM).")
        for part in [text.title, text.body] {
            #expect(!part.contains("Secret") && !part.contains("WING") && !part.contains("Removed"))
        }
        let allProtected = PlaylistFailure.notificationText(playlist: "S", failures: [failures[0]], isPrivate: true)
        #expect(allProtected.body == "1 video from a private window couldn’t be added. It’s protected (DRM).")
    }

    @Test func reasonsMapFromErrorsAndProblems() {
        #expect(PlaylistFailure.Reason(MediaError.drmProtected) == .protected)
        #expect(PlaylistFailure.Reason(MediaError.unavailable) == .unreadable)
        #expect(PlaylistFailure.Reason(PlaylistEntryProblem.needsFFmpeg) == .needsFFmpeg)
        #expect(PlaylistFailure.Reason(PlaylistEntryProblem.protected) == .protected)
    }

    @Test func batchBannerOneNamedPlaylist() {
        let b = [PlaylistBatchProgress(playlistTitle: "Open Movies", done: 2, total: 10)]
        #expect(PlaylistBatchProgress.bannerText(b) == "Adding 3 of 10 from “Open Movies”…")
    }

    @Test func batchBannerAggregatesSeveralPlaylists() {
        let b = [PlaylistBatchProgress(playlistTitle: "A", done: 2, total: 10),
                 PlaylistBatchProgress(playlistTitle: nil, done: 0, total: 4)]
        #expect(PlaylistBatchProgress.bannerText(b) == "Adding 12 videos from 2 playlists…")
        #expect(PlaylistBatchProgress.bannerText([PlaylistBatchProgress(playlistTitle: nil, done: 0, total: 3)])
                == "Adding 1 of 3 playlist videos…")
        #expect(PlaylistBatchProgress.bannerText([]) == nil)
    }

    @Test func wordingFollowsTheKind() {
        let t = PlaylistFailure.notificationText(playlist: "Tech house", failures: failures, isPrivate: false, kind: .audio)
        #expect(t.title == "2 tracks from “Tech house” weren’t added")
        let p = PlaylistFailure.notificationText(playlist: "S", failures: failures, isPrivate: true, kind: .unknown)
        #expect(p.title == "Some playlist items weren’t added")
        #expect(p.body.hasPrefix("2 items from a private window"))
        #expect(MediaKind.audio.count(1) == "1 track" && MediaKind.video.count(3) == "3 videos" && MediaKind.unknown.count(2) == "2 items")
    }

    @Test func batchBannerUsesTheKind() {
        let one = [PlaylistBatchProgress(playlistTitle: nil, done: 0, total: 3, kind: .audio)]
        #expect(PlaylistBatchProgress.bannerText(one) == "Adding 1 of 3 playlist tracks…")
        let audio = [PlaylistBatchProgress(playlistTitle: "A", done: 0, total: 2, kind: .audio),
                     PlaylistBatchProgress(playlistTitle: "B", done: 0, total: 3, kind: .audio)]
        #expect(PlaylistBatchProgress.bannerText(audio) == "Adding 5 tracks from 2 playlists…")
        let mixed = [PlaylistBatchProgress(playlistTitle: "A", done: 0, total: 2, kind: .audio),
                     PlaylistBatchProgress(playlistTitle: "B", done: 0, total: 3, kind: .video)]
        #expect(PlaylistBatchProgress.bannerText(mixed) == "Adding 5 items from 2 playlists…")
    }
}

@Suite struct PlaylistEntryTitleTests {
    static func entry(_ url: String, title: String? = nil) throws -> PlaylistEntry {
        let t = title.map { ",\"title\":\"\($0)\"" } ?? ",\"title\":null"
        return try JSONDecoder().decode(PlaylistEntry.self, from: Data("{\"id\":\"1\",\"url\":\"\(url)\"\(t)}".utf8))
    }

    @Test func realTitleWins() throws {
        let title = try Self.entry("https://soundcloud.com/a/b", title: "  Real Name ").listTitle(at: 0)
        #expect(title == PlaylistEntryTitle(text: "Real Name", isFromLink: false))
    }

    @Test func untitledEntriesGetAnApproximateNameFromTheirURL() throws {
        #expect(try Self.entry("https://soundcloud.com/weiss/premiere-weiss-i-believe").listTitle(at: 0)
                == PlaylistEntryTitle(text: "Premiere Weiss I Believe", isFromLink: true))
        #expect(try Self.entry("https://soundcloud.com/x/caf%C3%A9_del_mar-mix").listTitle(at: 0).text == "Café Del Mar Mix")
        #expect(try Self.entry("https://soundcloud.com/x/track-one?in=y/sets/z").listTitle(at: 0).text == "Track One")
    }

    @Test func idsAndEmptyPathsFallBackToTrackN() throws {
        #expect(try Self.entry("https://api.soundcloud.com/tracks/123456").listTitle(at: 4)
                == PlaylistEntryTitle(text: "Track 5", isFromLink: false))
        #expect(try Self.entry("https://example.com/").listTitle(at: 0).text == "Track 1")
        #expect(try Self.entry("https://www.youtube.com/watch?v=abc").listTitle(at: 1).text == "Track 2")
    }

    /// Notifications never show a name guessed from the link: the real title, else "Track N".
    @Test func knownTitleNeverUsesTheLink() throws {
        #expect(try Self.entry("https://soundcloud.com/weiss/premiere-weiss-i-believe").knownTitle(at: 2) == "Track 3")
        #expect(try Self.entry("https://soundcloud.com/w/x", title: "Real").knownTitle(at: 0) == "Real")
    }
}

@Suite struct TextFitTests {
    /// 10 points per character.
    let measure: (String) -> Double = { Double($0.count) * 10 }

    @Test func shortTextIsUnchanged() {
        #expect(TextFit.truncate("Off", maxWidth: 100, measure: measure) == "Off")
        #expect(TextFit.truncate("Off", maxWidth: nil, measure: measure) == "Off")
    }

    @Test func longTextEndsWithAnEllipsisAndFits() {
        let out = TextFit.truncate("Chinese, Traditional (auto)", maxWidth: 120, measure: measure)
        #expect(out == "Chinese, Tr…")
        #expect(measure(out) <= 120)
    }

    @Test func trailingSpacesAndPunctuationAreDroppedBeforeTheEllipsis() {
        #expect(TextFit.truncate("Chinese, Traditional", maxWidth: 90, measure: measure) == "Chinese…")
    }

    @Test func tinyWidthStillShowsSomething() {
        #expect(TextFit.truncate("English", maxWidth: 5, measure: measure) == "E…")
    }
}
