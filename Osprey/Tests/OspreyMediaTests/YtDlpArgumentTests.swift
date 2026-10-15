import Foundation
import Testing
@testable import OspreyMedia

/// yt-dlp must ignore the user's config files and never read a URL as an option.
@Suite struct YtDlpArgumentTests {
    private func hlsFormat() -> MediaFormat {
        try! JSONDecoder().decode(MediaFormat.self, from: Data(#"{"format_id":"hls-720","ext":"mp4","protocol":"m3u8_native"}"#.utf8))
    }

    @Test func extractorIgnoresConfigAndEndsOptionsBeforeTheURL() async throws {
        let json = try #require(Bundle.module.url(forResource: "youtube_like", withExtension: "json", subdirectory: "Fixtures"))
        let fake = try FakeTool(stdoutFile: json)
        defer { fake.cleanUp() }
        _ = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://www.youtube.com/watch?v=abc123")!,
                                                                    cookieHeader: "SID=1", playlist: false)
        let args = try fake.arguments()
        #expect(args.contains("--ignore-config"))
        #expect(args.count >= 2 && args[args.count - 2] == "--")
        #expect(args.last == "https://www.youtube.com/watch?v=abc123")
        #expect(try #require(args.firstIndex(of: "--")) > (try #require(args.firstIndex(of: "--cookies"))))
    }

    @Test func playlistProbeAlsoIgnoresConfig() async throws {
        let json = try #require(Bundle.module.url(forResource: "playlist", withExtension: "json", subdirectory: "Fixtures"))
        let fake = try FakeTool(stdoutFile: json)
        defer { fake.cleanUp() }
        _ = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://www.youtube.com/playlist?list=PL1")!,
                                                                    cookieHeader: nil, playlist: true)
        let args = try fake.arguments()
        #expect(args.contains("--ignore-config"))
        #expect(args[args.count - 2] == "--")
    }

    @Test(arguments: ["file:///etc/hosts", "ftp://x.test/v", "javascript:alert(1)", "--batch-file=/etc/hosts", "https:///nohost"])
    func probeRejectsAnythingButHTTP(_ text: String) async throws {
        let fake = try FakeTool(stdoutLines: ["{}"])
        defer { fake.cleanUp() }
        let url = try #require(URL(string: text))
        await #expect(throws: MediaError.unsupported) {
            _ = try await MediaExtractor(tools: tools(with: fake)).probe(url, cookieHeader: nil, playlist: false)
        }
        #expect(!FileManager.default.fileExists(atPath: fake.argsFile.path(percentEncoded: false)))   // yt-dlp never ran
    }

    @Test func fragmentDownloadIgnoresConfigAndEndsOptionsBeforeTheURL() async throws {
        let fake = try FakeTool(writesDestination: true)
        let dir = TestTemp.root.appending(path: "frag-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let job = YtDlpFragmentDownload(id: UUID(), pageURL: URL(string: "https://x.test/watch?v=1")!, format: hlsFormat(),
                                        destination: dir.appending(path: "video.mp4"), tools: tools(with: fake),
                                        cookieHeader: nil, speedLimit: nil)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        let args = try fake.arguments()
        #expect(args.contains("--ignore-config"))
        #expect(args[args.count - 2] == "--" && args.last == "https://x.test/watch?v=1")
    }

    @Test func fragmentDownloadRefusesANonHTTPPage() async throws {
        let fake = try FakeTool(writesDestination: true)
        let dir = TestTemp.root.appending(path: "frag-dest-\(UUID().uuidString)")
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let job = YtDlpFragmentDownload(id: UUID(), pageURL: URL(string: "file:///etc/hosts")!, format: hlsFormat(),
                                        destination: dir.appending(path: "video.mp4"), tools: tools(with: fake),
                                        cookieHeader: nil, speedLimit: nil)
        await job.start()
        guard case .failed = await job.snapshot().state else { Issue.record("expected failed"); return }
        #expect(!FileManager.default.fileExists(atPath: fake.argsFile.path(percentEncoded: false)))
    }

    @Test func versionCheckIgnoresConfig() async throws {
        let fake = try FakeTool(stdoutLines: ["2026.01.01"])
        defer { fake.cleanUp() }
        #expect(await tools(with: fake).version(.ytdlp) == "2026.01.01")
        #expect(try fake.arguments() == ["--ignore-config", "--version"])
    }

    @Test func playlistEntriesWithUnsafeURLsAreDropped() throws {
        let json = """
        {"_type":"playlist","id":"PL","title":"P","entries":[
          {"id":"a","url":"--batch-file=/etc/hosts"},
          {"id":"b","url":"file:///etc/passwd"},
          {"id":"c","url":"https://www.youtube.com/watch?v=c"},
          {"id":"d","url":"d-only-an-id","webpage_url":"https://www.youtube.com/watch?v=d"},
          {"id":"e","url":"https:///nohost"},
          {"id":"f","url":"-o","webpage_url":"--exec=rm"},
          {"id":"g","url":"http://vimeo.com/7"}
        ]}
        """
        guard case .playlist(let list) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected playlist"); return }
        #expect(list.entries.map(\.id) == ["c", "d", "g"])
        #expect(list.entries.map(\.url.absoluteString) == ["https://www.youtube.com/watch?v=c", "https://www.youtube.com/watch?v=d",
                                                           "http://vimeo.com/7"])
    }

    @Test func formatsChangedUsesTheSpecText() {
        #expect(MediaError.formatsChanged.userMessage == "The site changed this media's formats — start it again")
    }
}
