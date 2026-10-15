import Foundation
import Testing
@testable import OspreyMedia

@Suite struct PrivacyTests {
    // MARK: M5 subtitles

    @Test func subtitleTracksMustBeWebAddresses() throws {
        let json = """
        {"id":"x","title":"T","formats":[],
         "subtitles":{"en":[{"ext":"vtt","url":"file:///etc/passwd"},{"ext":"srt","url":"https://subs.example/en.srt"}],
                      "de":[{"ext":"vtt","url":"--exec=rm"}]},
         "automatic_captions":{"fr":[{"ext":"vtt","url":"ftp://x.test/fr.vtt"}]}}
        """
        guard case .single(let info) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected single"); return }
        #expect(info.subtitles["en"]?.map(\.url.absoluteString) == ["https://subs.example/en.srt"])
        #expect(info.subtitles["de"] == nil)
        #expect(info.automaticCaptions.isEmpty)
    }

    // MARK: M5 private thumbnails

    @Test func privateThumbnailsUseAnEphemeralSessionWithNoDiskCache() async throws {
        let server = try MiniHTTPServer(bodies: ["/thumb.jpg": Data("jpeg".utf8)])
        try await server.start()
        defer { server.stop() }
        let url = server.url(path: "/thumb.jpg")
        let configuration = MediaThumbnail.configuration(isPrivate: true)
        #expect((configuration.urlCache?.diskCapacity ?? 0) == 0)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        let data = await MediaThumbnail.load(url, isPrivate: true)
        #expect(data == Data("jpeg".utf8))
        #expect(URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil)
        #expect(server.requestedPaths == ["/thumb.jpg"])
    }

    @Test func thumbnailsMustBeWebAddresses() async {
        #expect(await MediaThumbnail.load(URL(fileURLWithPath: "/etc/hosts"), isPrivate: false) == nil)
        #expect(await MediaThumbnail.load(URL(fileURLWithPath: "/etc/hosts"), isPrivate: true) == nil)
    }

    // MARK: M6 environment

    @Test func toolEnvironmentDropsDyldAndPythonVariables() {
        let env = ProcessRunner.sanitizedEnvironment([
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "DYLD_LIBRARY_PATH": "/x", "DYLD_FRAMEWORK_PATH": "/y",
            "PYTHONPATH": "/z", "PATH": "/usr/bin", "HOME": "/Users/me",
        ])
        #expect(env == ["PATH": "/usr/bin", "HOME": "/Users/me"])
    }
}
