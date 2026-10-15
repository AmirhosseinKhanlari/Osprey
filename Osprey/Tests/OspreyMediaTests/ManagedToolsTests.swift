import CryptoKit
import Foundation
import Testing
@testable import OspreyMedia

/// Osprey keeps its own yt-dlp: a Homebrew copy is only a fallback when the managed one can't be installed.
@Suite struct ManagedToolsTests {
    final class Env: @unchecked Sendable {
        let root = TestTemp.root.appending(path: "managed-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let managed: URL
        let brew: URL
        let suite = "osprey-test-\(UUID().uuidString)"
        let defaults: UserDefaults
        let server: MiniHTTPServer
        var tools: MediaTools { MediaTools(managedFolder: managed, homebrewFolders: [brew]) }

        init() async throws {
            managed = root.appending(path: "Tools", directoryHint: .isDirectory)
            brew = root.appending(path: "brew", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: brew, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            server = try MiniHTTPServer(bodies: [:])
            try await server.start()
        }

        /// A yt-dlp stand-in: `--version` prints `version`; anything else prints `json` (exit 0) or `error` (exit 1).
        static func script(version: String, json: String? = nil, error: String? = nil) -> Data {
            var s = "#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = \"--version\" ]; then echo \(version); exit 0; fi; done\n"
            if let json { s += "cat <<'EOF'\n\(json)\nEOF\nexit 0\n" }
            if let error { s += "echo '\(error)' >&2\nexit 1\n" }
            return Data(s.utf8)
        }

        func installBrew(_ data: Data) throws {
            let tool = brew.appending(path: "yt-dlp")
            try data.write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        }

        func serveManaged(_ binary: Data) {
            server.setBody(binary, for: "/yt-dlp_macos")
            let hex = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
            server.setBody(Data("\(hex)  yt-dlp_macos\n".utf8), for: "/SHA2-256SUMS")
        }

        var source: ToolSource {
            ToolSource(binaryURL: server.url(path: "/yt-dlp_macos"), checksumURL: server.url(path: "/SHA2-256SUMS"),
                       checksumEntryName: "yt-dlp_macos", archive: false)
        }

        let clock = TestClock()

        func installer() -> ToolInstaller {
            let clock = self.clock
            return ToolInstaller(tools: tools, defaults: defaults, ytdlpSource: source, now: { clock.now })
        }

        func lookup() -> MediaLookup {
            MediaLookup(tools: tools, installer: installer(), extractor: MediaExtractor(tools: tools))
        }

        func cleanup() {
            server.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static let videoJSON = #"{"id":"v1","title":"Managed","formats":[{"format_id":"18","ext":"mp4","protocol":"https","url":"https://m.example/18","vcodec":"avc1","acodec":"mp4a.40.2","height":360}]}"#

    @Test func ensureManagedInstallsOverHomebrew() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        try env.installBrew(Env.script(version: "brew"))
        env.serveManaged(Env.script(version: "managed"))
        let progress = ProgressLog()
        let location = try await env.installer().ensureManaged(.ytdlp) { progress.add($0) }
        #expect(location.source == .managed)
        #expect(env.tools.locate(.ytdlp)?.source == .managed)        // the managed copy now wins the lookup
        #expect(env.server.requestedPaths.contains("/yt-dlp_macos"))
        #expect(progress.values.last == 1.0)
    }

    @Test func ensureManagedKeepsAnExistingManagedCopy() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serveManaged(Env.script(version: "managed"))
        _ = try await env.installer().ensureManaged(.ytdlp) { _ in }
        let before = env.server.requestedPaths.count
        let again = try await env.installer().ensureManaged(.ytdlp) { _ in }
        #expect(again.source == .managed)
        #expect(env.server.requestedPaths.count == before)
    }

    @Test func failedInstallFallsBackToHomebrew() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        try env.installBrew(Env.script(version: "brew"))
        // Nothing served: the download answers 404, as if offline.
        let location = try await env.installer().ensureManaged(.ytdlp) { _ in }
        #expect(location.source == .homebrew)
    }

    @Test func failedInstallWithoutHomebrewThrows() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        await #expect(throws: MediaError.self) { _ = try await env.installer().ensureManaged(.ytdlp) { _ in } }
    }

    @Test func homebrewExtractionFailureInstallsManagedAndRetriesOnce() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        try env.installBrew(Env.script(version: "brew", error: "ERROR: [youtube] v1: The page needs to be reloaded."))
        let lookup = env.lookup()
        // The managed install failed earlier (offline), so the lookup starts on Homebrew; now the server is back.
        env.serveManaged(Env.script(version: "managed", json: Self.videoJSON))
        let events = EventLog()
        let result = try await lookup.probe(URL(string: "https://www.youtube.com/watch?v=v1")!, cookieHeader: nil, playlist: false) {
            events.add($0)
        }
        guard case .single(let info) = result else { Issue.record("expected a single video"); return }
        #expect(info.title == "Managed")
        #expect(env.tools.locate(.ytdlp)?.source == .managed)
        // Install progress first, then one "extracting" once the install returned and the retry starts.
        #expect(events.values.first == .installing(nil))
        #expect(events.values.last == .extracting)
        #expect(events.values.filter { $0 == .extracting }.count == 1)
    }

    @Test func managedExtractionFailureIsNotRetried() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serveManaged(Env.script(version: "managed", error: "ERROR: Unsupported URL: https://x.test/"))
        _ = try await env.installer().ensureManaged(.ytdlp) { _ in }
        let before = env.server.requestedPaths.count
        await #expect(throws: MediaError.unsupported) {
            _ = try await env.lookup().probe(URL(string: "https://x.test/")!, cookieHeader: nil, playlist: false) { _ in }
        }
        #expect(env.server.requestedPaths.count == before)
    }

    @Test func homebrewFailureStandsWhenManagedInstallFails() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        try env.installBrew(Env.script(version: "brew", error: "ERROR: Unsupported URL: https://x.test/"))
        await #expect(throws: MediaError.unsupported) {
            _ = try await env.lookup().probe(URL(string: "https://x.test/")!, cookieHeader: nil, playlist: false) { _ in }
        }
        #expect(env.tools.locate(.ytdlp)?.source == .homebrew)
    }

    @Test func failedInstallBacksOffTenMinutesWhenHomebrewExists() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        try env.installBrew(Env.script(version: "brew"))
        #expect(try await env.installer().ensureManaged(.ytdlp) { _ in }.source == .homebrew)     // 404: offline
        let afterFailure = env.server.requestedPaths.count
        #expect(afterFailure > 0)
        env.serveManaged(Env.script(version: "managed"))
        env.clock.advance(by: 5 * 60)
        #expect(try await env.installer().ensureManaged(.ytdlp) { _ in }.source == .homebrew)      // inside the window
        #expect(env.server.requestedPaths.count == afterFailure)
        // The safety net doesn't install inside the window either.
        try env.installBrew(Env.script(version: "brew", error: "ERROR: Unsupported URL: https://x.test/"))
        await #expect(throws: MediaError.unsupported) {
            _ = try await env.lookup().probe(URL(string: "https://x.test/")!, cookieHeader: nil, playlist: false) { _ in }
        }
        #expect(env.server.requestedPaths.count == afterFailure)
        // No "Setting up…" flash while backed off: the Homebrew copy is used as is.
        #expect(!env.lookup().needsSetup)
        env.clock.advance(by: 6 * 60)                                                                   // 11 min later
        #expect(env.lookup().needsSetup)
        #expect(try await env.installer().ensureManaged(.ytdlp) { _ in }.source == .managed)
        #expect(env.server.requestedPaths.count > afterFailure)
    }

    @Test func withoutHomebrewEveryAttemptInstalls() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        await #expect(throws: MediaError.self) { _ = try await env.installer().ensureManaged(.ytdlp) { _ in } }
        let afterFailure = env.server.requestedPaths.count
        env.serveManaged(Env.script(version: "managed"))
        env.clock.advance(by: 60)
        #expect(try await env.installer().ensureManaged(.ytdlp) { _ in }.source == .managed)        // Retry works at once
        #expect(env.server.requestedPaths.count > afterFailure)
    }

    /// The flat lookup can come back without formats (single) or as a one-entry list: then the same URL (or that
    /// entry) is read again alone, and the single pane shows. A two-entry list stays a playlist. No other extra lookups.
    @Test func flatLookupFallsBackToASingleRead() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let log = env.root.appending(path: "calls.txt").path(percentEncoded: false)
        let formatless = #"{"id":"f","title":"Formatless","formats":[]}"#
        let one = #"{"_type":"playlist","id":"p1","title":"One","entries":[{"id":"e1","url":"https://x.test/entry1","title":"E1"}]}"#
        let two = #"{"_type":"playlist","id":"p2","title":"Two","entries":[{"id":"a","url":"https://x.test/a"},{"id":"b","url":"https://x.test/b"}]}"#
        var script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 1; exit 0; fi\n"
        script += "for a in \"$@\"; do last=\"$a\"; done\nmode=single; case \" $* \" in *' --flat-playlist '*) mode=flat;; esac\n"
        script += "echo \"$mode $last\" >> '\(log)'\n"
        script += "case \"$mode $last\" in\n"
        script += "  'flat https://x.test/formatless') echo '\(formatless)';;\n"
        script += "  'flat https://x.test/one') echo '\(one)';;\n"
        script += "  'flat https://x.test/two') echo '\(two)';;\n"
        script += "  *) echo '\(Self.videoJSON)';;\nesac\n"
        env.serveManaged(Data(script.utf8))
        _ = try await env.installer().ensureManaged(.ytdlp) { _ in }
        func calls() -> [String] {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                .filter { !$0.hasSuffix("--version") }             // the install's own check of the new binary
        }

        guard case .single(let a) = try await env.lookup().probe(URL(string: "https://x.test/formatless")!, cookieHeader: nil, progress: { _ in })
        else { Issue.record("formatless: expected single"); return }
        #expect(!a.formats.isEmpty)
        #expect(calls() == ["flat https://x.test/formatless", "single https://x.test/formatless"], "\(calls())")

        try? FileManager.default.removeItem(atPath: log)
        guard case .single(let b) = try await env.lookup().probe(URL(string: "https://x.test/one")!, cookieHeader: nil, progress: { _ in })
        else { Issue.record("one entry: expected single"); return }
        #expect(b.title == "Managed")
        #expect(calls() == ["flat https://x.test/one", "single https://x.test/entry1"])

        try? FileManager.default.removeItem(atPath: log)
        guard case .playlist(let c) = try await env.lookup().probe(URL(string: "https://x.test/two")!, cookieHeader: nil, progress: { _ in })
        else { Issue.record("two entries: expected playlist"); return }
        #expect(c.entries.count == 2)
        #expect(calls() == ["flat https://x.test/two"])

        try? FileManager.default.removeItem(atPath: log)
        guard case .single = try await env.lookup().probe(URL(string: "https://x.test/video")!, cookieHeader: nil, progress: { _ in })
        else { Issue.record("video: expected single"); return }
        #expect(calls() == ["flat https://x.test/video"])            // a normal single: one lookup
    }

    @Test func messagesDoNotSendUsersToHomebrew() {
        for error in [MediaError.toolMissing("yt-dlp"), .installFailed("checksum mismatch")] {
            #expect(!error.userMessage.contains("Homebrew"))
            #expect(error.userMessage.contains("media downloader"))
        }
    }

    /// The user's kind of page isn't known before the lookup: messages say "media", not "video".
    @Test func lookupMessagesDoNotAssumeVideo() {
        for error in [MediaError.unsupported, .drmProtected, .loginRequired, .unavailable, .extractionFailed("x"), .formatsChanged] {
            let text = error.userMessage.lowercased()
            #expect(!text.contains("this video") && !text.contains("a video"), "\(error)")
        }
    }

    /// A SoundCloud set (no "playlist" in the URL) is looked up flat and comes back as a playlist; a YouTube video
    /// named inside a list is looked up alone.
    @Test func lookupIsFlatUnlessTheURLNamesAVideoInAList() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let argsFile = env.root.appending(path: "args.txt").path(percentEncoded: false)
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 1; exit 0; fi\nprintf '%s\\n' \"$@\" > '\(argsFile)'\n"
            + "case \" $* \" in *' --flat-playlist '*) echo '{\"_type\":\"playlist\",\"id\":\"s\",\"title\":\"Tech house\",\"entries\":[{\"id\":\"1\",\"url\":\"https://soundcloud.com/a/one\",\"title\":null},{\"id\":\"2\",\"url\":\"https://soundcloud.com/a/two\",\"title\":null}]}';;\n"
            + "*) echo '\(Self.videoJSON)';; esac\n"
        env.serveManaged(Data(script.utf8))
        _ = try await env.installer().ensureManaged(.ytdlp) { _ in }
        let set = try await env.lookup().probe(URL(string: "https://soundcloud.com/dan-mayers-2/sets/tech-house")!, cookieHeader: nil) { _ in }
        guard case .playlist(let list) = set else { Issue.record("expected the playlist pane"); return }
        #expect(list.title == "Tech house")
        #expect(try String(contentsOfFile: argsFile, encoding: .utf8).contains("--flat-playlist"))
        let one = try await env.lookup().probe(URL(string: "https://www.youtube.com/watch?v=v1&list=PL1")!, cookieHeader: nil) { _ in }
        guard case .single = one else { Issue.record("expected the single pane"); return }
        #expect(try String(contentsOfFile: argsFile, encoding: .utf8).contains("--no-playlist"))
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LookupProgress] = []
    func add(_ v: LookupProgress) { lock.withLock { stored.append(v) } }
    var values: [LookupProgress] { lock.withLock { stored } }
}
