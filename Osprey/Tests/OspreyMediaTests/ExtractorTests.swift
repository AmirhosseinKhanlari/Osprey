import Foundation
import Testing
@testable import OspreyMedia

func tools(with fake: FakeTool) -> MediaTools {
    MediaTools(managedFolder: fake.folder, homebrewFolders: [])
}

@Suite struct ExtractorTests {
    @Test func probesASingleVideoWithTheRightArguments() async throws {
        let json = try #require(Bundle.module.url(forResource: "youtube_like", withExtension: "json", subdirectory: "Fixtures"))
        let fake = try FakeTool(stdoutFile: json)
        let result = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://www.youtube.com/watch?v=abc123")!,
                                                                             cookieHeader: nil, playlist: false)
        guard case .single(let info) = result else { Issue.record("expected single"); return }
        #expect(info.id == "abc123")
        let args = try fake.arguments()
        #expect(args.contains("-J") && args.contains("--no-playlist") && !args.contains("--cookies"))
        #expect(args.last == "https://www.youtube.com/watch?v=abc123")
        #expect(!args.contains("--allow-unplayable-formats"))
    }

    @Test func playlistModeUsesFlatPlaylist() async throws {
        let json = try #require(Bundle.module.url(forResource: "playlist", withExtension: "json", subdirectory: "Fixtures"))
        let fake = try FakeTool(stdoutFile: json)
        let result = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://www.youtube.com/playlist?list=PL1")!,
                                                                             cookieHeader: nil, playlist: true)
        guard case .playlist(let p) = result else { Issue.record("expected playlist"); return }
        #expect(p.entries.count == 3)
        #expect(try fake.arguments().contains("--flat-playlist"))
    }

    @Test func cookiesArePassedAsAPrivateFileAndDeleted() async throws {
        let json = try #require(Bundle.module.url(forResource: "youtube_like", withExtension: "json", subdirectory: "Fixtures"))
        let fake = try FakeTool(stdoutFile: json)
        _ = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://www.youtube.com/watch?v=abc123")!,
                                                                    cookieHeader: "SID=secret; HSID=x", playlist: false)
        let args = try fake.arguments()
        let index = try #require(args.firstIndex(of: "--cookies"))
        let path = args[index + 1]
        #expect(!FileManager.default.fileExists(atPath: path))          // deleted after the probe
    }

    @Test(arguments: [
        ("ERROR: Unsupported URL: https://x.test/page", MediaError.unsupported),
        ("ERROR: [youtube] abc: Sign in to confirm your age", MediaError.loginRequired),
        ("ERROR: [youtube] abc: Private video", MediaError.unavailable),
        ("ERROR: This video is DRM protected", MediaError.drmProtected)
    ])
    func mapsErrors(stderr: String, expected: MediaError) async throws {
        let fake = try FakeTool(stderr: stderr, exitCode: 1)
        await #expect(throws: expected) {
            _ = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://x.test/v")!, cookieHeader: nil, playlist: false)
        }
    }

    @Test func unknownErrorsAreRedactedToHostOnly() async throws {
        let fake = try FakeTool(stderr: "ERROR: boom while fetching https://cdn.x.test/v.mp4?token=SECRET123 now", exitCode: 1)
        do {
            _ = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://x.test/v")!, cookieHeader: nil, playlist: false)
            Issue.record("expected throw")
        } catch let MediaError.extractionFailed(text) {
            #expect(text.contains("cdn.x.test"))
            #expect(!text.contains("SECRET123") && !text.contains("token") && !text.contains("https://"))
        }
    }

    @Test func drmOnlyResultThrowsProtected() async throws {
        let json = try #require(Bundle.module.url(forResource: "drm_only", withExtension: "json", subdirectory: "Fixtures"))
        let fake = try FakeTool(stdoutFile: json)
        await #expect(throws: MediaError.drmProtected) {
            _ = try await MediaExtractor(tools: tools(with: fake)).probe(URL(string: "https://x.test/v")!, cookieHeader: nil, playlist: false)
        }
    }

    @Test func missingToolIsReported() async {
        let empty = TestTemp.root.appending(path: "no-tools-\(UUID().uuidString)")
        await #expect(throws: MediaError.toolMissing("yt-dlp")) {
            _ = try await MediaExtractor(tools: MediaTools(managedFolder: empty, homebrewFolders: [])).probe(
                URL(string: "https://x.test/v")!, cookieHeader: nil, playlist: false)
        }
    }

    @Test func timesOut() async throws {
        let fake = try FakeTool(sleepSeconds: 5)
        let runner: @Sendable (URL, [String], TimeInterval) async throws -> ProcessResult = { exe, args, _ in
            try await ProcessRunner.run(exe, args, timeout: 0.5)
        }
        let started = Date()
        await #expect(throws: MediaError.timedOut) {
            _ = try await MediaExtractor(tools: tools(with: fake), runner: runner).probe(URL(string: "https://x.test/v")!, cookieHeader: nil, playlist: false)
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func drainsLargeOutputWithoutDeadlock() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/head"), ["-c", "4000000", "/dev/zero"], timeout: 20)
        #expect(r.status == 0 && r.stdout.count == 4_000_000)
    }

    @Test func stripsPythonVariables() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), [], timeout: 10,
                                            environment: ["PYTHONHOME": "/x", "PYTHONPATH": "/y", "KEEP": "1"])
        let text = String(decoding: r.stdout, as: UTF8.self)
        #expect(text.contains("KEEP=1") && !text.contains("PYTHON"))
    }

    @Test func cancellationTerminatesTheChild() async throws {
        let started = Date()
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 60) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func versionOfFakeTool() async throws {
        let fake = try FakeTool(stderr: "")
        let located = try #require(MediaTools(managedFolder: fake.folder, homebrewFolders: []).locate(.ytdlp))
        #expect(located.source == .managed)
        #expect(MediaTools(managedFolder: fake.folder, homebrewFolders: []).locate(.ffmpeg) == nil)
    }
}

@Suite struct ExtractorErrorLineTests {
    /// With -J, yt-dlp writes its progress lines to stderr before the error: the ERROR line is the one that counts.
    @Test func theErrorLineWinsOverEarlierInfoLines() {
        let stderr = """
        [soundcloud] catzndogz/they-frontin: Downloading info JSON
        [soundcloud] Downloading main page
        ERROR: [soundcloud] catzndogz/they-frontin: Unable to download JSON metadata: HTTP Error 403: Forbidden
        """
        let error = MediaExtractor.map(stderr: stderr)
        guard case .extractionFailed(let detail) = error else { Issue.record("\(error)"); return }
        #expect(detail.contains("HTTP Error 403"))
        #expect(PlaylistTitleResolver.isRateLimit(error))
        #expect(PlaylistTitleResolver.isRateLimit(.extractionFailed("ERROR: x: HTTP Error 429: Too Many Requests")))
        #expect(!PlaylistTitleResolver.isRateLimit(.unavailable))
        #expect(!PlaylistTitleResolver.isRateLimit(.extractionFailed("ERROR: something else")))
    }
}
