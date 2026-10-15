import Foundation
import Testing
@testable import OspreyMedia

/// YouTube answers HTTP 429 for direct auto-translated caption URLs (`tlang=`), but serves the same captions as an HLS
/// playlist of WebVTT segments (yt-dlp's `m3u8_native` track). Those are joined into one WebVTT file.
@Suite struct HLSSubtitleTests {
    static let playlist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-TARGETDURATION:600
    #EXTINF:600,
    https://www.youtube.com/api/timedtext?lang=fr&range=0-600
    #EXTINF:600,
    /api/timedtext?lang=fr&range=600-600
    #EXT-X-ENDLIST
    """

    @Test func segmentsAreTheNonCommentLinesResolvedAgainstThePlaylist() throws {
        let base = URL(string: "https://manifest.googlevideo.com/api/manifest/playlist/index.m3u8")!
        let urls = try HLSSubtitles.segments(in: Self.playlist, playlistURL: base)
        #expect(urls.map(\.absoluteString) == [
            "https://www.youtube.com/api/timedtext?lang=fr&range=0-600",
            "https://manifest.googlevideo.com/api/timedtext?lang=fr&range=600-600",
        ])
    }

    @Test func aNonPlaylistOrANonWebSegmentIsRefused() {
        let base = URL(string: "https://m.example/a.m3u8")!
        #expect(throws: HLSSubtitles.Problem.self) { try HLSSubtitles.segments(in: "WEBVTT\n", playlistURL: base) }
        #expect(throws: HLSSubtitles.Problem.self) {
            try HLSSubtitles.segments(in: "#EXTM3U\n#EXTINF:1,\nfile:///etc/passwd\n", playlistURL: base)
        }
        #expect(throws: HLSSubtitles.Problem.self) { try HLSSubtitles.segments(in: "#EXTM3U\n", playlistURL: base) }
    }

    @Test func joiningKeepsTheFirstHeaderAndDropsCuesRepeatedAcrossABoundary() {
        let first = """
        WEBVTT
        Kind: captions
        Language: fr

        00:00:00.100 --> 00:00:02.000
        Bonjour

        00:09:58.000 --> 00:10:00.500
        Au revoir
        """
        let second = """
        WEBVTT
        Kind: captions
        Language: fr

        00:09:58.000 --> 00:10:00.500
        Au revoir

        00:10:00.500 --> 00:10:02.000
        Encore
        """
        let joined = HLSSubtitles.join([first, second])
        #expect(joined.hasPrefix("WEBVTT\nKind: captions\nLanguage: fr\n\n"))
        #expect(joined.components(separatedBy: "-->").count - 1 == 3)
        #expect(joined.components(separatedBy: "Au revoir").count - 1 == 1)
        #expect(joined.contains("00:10:00.500 --> 00:10:02.000\nEncore"))
        #expect(joined.components(separatedBy: "WEBVTT").count - 1 == 1)
    }

    @Test func crlfSegmentsJoinToo() {
        let joined = HLSSubtitles.join(["WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nUn\r\n",
                                        "WEBVTT\r\n\r\n00:00:03.000 --> 00:00:04.000\r\nDeux\r\n"])
        #expect(joined == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nUn\n\n00:00:03.000 --> 00:00:04.000\nDeux\n")
    }

    // MARK: Track choice

    static func info(auto: String) throws -> MediaInfo {
        try infoJSON([fmt("v", #""vcodec":"avc1","acodec":"mp4a.40.2","height":360"#)],
                     extra: ",\"automatic_captions\":{\"fr\":[\(auto)]}")
    }

    static let hls = #"{"ext":"vtt","protocol":"m3u8_native","url":"https://manifest.example/fr/index.m3u8"}"#
    static let srt = #"{"ext":"srt","url":"https://www.youtube.com/api/timedtext?tlang=fr&fmt=srt"}"#
    static let vtt = #"{"ext":"vtt","url":"https://www.youtube.com/api/timedtext?tlang=fr&fmt=vtt"}"#

    @Test func directTracksComeFirstAndTheHLSTrackIsTheLastResort() throws {
        let i = try Self.info(auto: [Self.hls, Self.srt, Self.vtt].joined(separator: ","))
        let menu = SubtitleMenu(info: i, chosen: nil, systemLanguage: nil, preferredLanguages: [])
        let tracks = menu.tracks(for: SubtitleChoice(language: "fr", isAuto: true), in: i)
        #expect(tracks.map(\.ext) == ["srt", "vtt", "vtt"])
        #expect(tracks.map(\.isHLS) == [false, false, true])
        #expect(menu.track(for: SubtitleChoice(language: "fr", isAuto: true), in: i)?.ext == "srt")
    }

    @Test func aLanguageWithOnlyAnHLSTrackIsStillListed() throws {
        let i = try Self.info(auto: Self.hls)
        let menu = SubtitleMenu(info: i, chosen: nil, systemLanguage: nil, preferredLanguages: [])
        #expect(menu.auto == ["fr"])
        #expect(menu.track(for: SubtitleChoice(language: "fr", isAuto: true), in: i)?.isHLS == true)
    }

    @Test func anHLSTrackIsRecognisedByItsAddressToo() {
        let byPath = SubtitleTrack(ext: "vtt", url: URL(string: "https://m.example/x/index.m3u8?a=1")!, name: nil)
        let direct = SubtitleTrack(ext: "vtt", url: URL(string: "https://m.example/x.vtt")!, name: nil)
        #expect(byPath.isHLS)
        #expect(!direct.isHLS)
    }
}
