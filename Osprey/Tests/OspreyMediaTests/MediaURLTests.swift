import Foundation
import Testing
@testable import OspreyMedia

@Suite struct MediaURLTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Cookie scope (a playlist's cookies only go to entries on the same site)

    @Test(arguments: [
        ("https://www.youtube.com/playlist?list=PL1", "https://www.youtube.com/watch?v=a"),
        ("https://www.youtube.com/playlist?list=PL1", "https://music.youtube.com/watch?v=a"),
        ("https://m.youtube.com/playlist?list=PL1", "https://youtube.com/watch?v=a"),
        ("https://WWW.YouTube.com/playlist", "https://www.youtube.com/watch?v=a"),
        ("https://vimeo.com/showcase/1", "https://player.vimeo.com/video/2"),
        ("https://www.bbc.co.uk/iplayer/x", "https://www.bbc.co.uk/iplayer/y"),
        ("http://127.0.0.1:8080/list", "http://127.0.0.1:9090/v"),
    ])
    func sameSiteEntriesGetTheCookies(page: String, entry: String) {
        #expect(MediaURL.mayShareCookies(from: url(page), with: url(entry)))
    }

    @Test(arguments: [
        ("https://www.youtube.com/playlist?list=PL1", "https://vimeo.com/2"),
        ("https://www.youtube.com/playlist?list=PL1", "https://youtube.com.evil.test/watch?v=a"),
        ("https://www.youtube.com/playlist?list=PL1", "https://notyoutube.com/watch?v=a"),
        ("https://www.youtube.com/playlist?list=PL1", "https://youtu.be/a"),
        ("https://www.bbc.co.uk/iplayer/x", "https://evil.co.uk/y"),
        ("http://127.0.0.1/list", "http://10.0.0.1/v"),
        ("https://www.youtube.com/playlist", "file:///etc/passwd"),
        ("https://localhost/list", "https://example.localhost/v"),
    ])
    func otherSitesDoNot(page: String, entry: String) {
        #expect(!MediaURL.mayShareCookies(from: url(page), with: url(entry)))
    }

    @Test func entryCookieHeaderIsNilForAnotherSite() {
        let page = url("https://www.youtube.com/playlist?list=PL1")
        #expect(MediaURL.cookieHeader("SID=1", from: page, for: url("https://www.youtube.com/watch?v=a")) == "SID=1")
        #expect(MediaURL.cookieHeader("SID=1", from: page, for: url("https://vimeo.com/2")) == nil)
        #expect(MediaURL.cookieHeader(nil, from: page, for: url("https://www.youtube.com/watch?v=a")) == nil)
    }

    // MARK: Playlist or single video

    /// Every lookup is flat (a playlist comes back as its entries; a lone video is still fully read), except a URL
    /// that names one video inside a list, which asks for just that video.
    @Test(arguments: [
        "https://www.youtube.com/playlist?list=PL123",
        "https://youtube.com/playlist?list=PL123&si=x",
        "https://music.youtube.com/playlist?list=OLAK5",
        "https://example.test/videos?list=abc",
        "https://vimeo.com/showcase/123/playlist",
        "https://soundcloud.com/dan-mayers-2/sets/tech-house",
        "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
        "https://example.test/watch?list=",
        "https://vimeo.com/76979871",
    ])
    func flatLookups(_ s: String) {
        #expect(!MediaURL.namesVideoInList(url(s)))
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=PL123",
        "https://www.youtube.com/watch?list=PL123&v=aqz-KE-bpKQ&index=3",
        "https://youtu.be/aqz-KE-bpKQ?list=PL123",
        "https://www.youtube.com/shorts/abc?list=PL1",
    ])
    func aVideoInsideAListIsLookedUpAlone(_ s: String) {
        #expect(MediaURL.namesVideoInList(url(s)))
    }

    @Test func siteKindFollowsKnownHosts() {
        #expect(MediaURL.siteKind(url("https://soundcloud.com/a/sets/b")) == .audio)
        #expect(MediaURL.siteKind(url("https://m.soundcloud.com/a")) == .audio)
        #expect(MediaURL.siteKind(url("https://artist.bandcamp.com/album/x")) == .audio)
        #expect(MediaURL.siteKind(url("https://www.mixcloud.com/a/b/")) == .audio)
        #expect(MediaURL.siteKind(url("https://audiomack.com/a/song/b")) == .audio)
        #expect(MediaURL.siteKind(url("https://www.youtube.com/watch?v=a")) == .video)
        #expect(MediaURL.siteKind(url("https://youtu.be/a")) == .video)
        #expect(MediaURL.siteKind(url("https://x.com/a/status/1")) == .video)
        #expect(MediaURL.siteKind(url("https://example.com/page")) == .unknown)
        #expect(MediaURL.siteKind(url("https://notsoundcloud.com/a")) == .unknown)
    }
}
