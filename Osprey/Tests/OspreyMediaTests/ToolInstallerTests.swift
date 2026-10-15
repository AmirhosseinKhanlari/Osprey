import CryptoKit
import Foundation
import Testing
@testable import OspreyMedia

@Suite struct ToolInstallerTests {
    final class Env: @unchecked Sendable {
        let root = TestTemp.root.appending(path: "installer-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let managed: URL
        let suite = "osprey-test-\(UUID().uuidString)"
        let defaults: UserDefaults
        let server: MiniHTTPServer
        let marker: URL
        var tools: MediaTools { MediaTools(managedFolder: managed, homebrewFolders: []) }

        init(bodies: [String: Data] = [:]) async throws {
            managed = root.appending(path: "Tools", directoryHint: .isDirectory)
            marker = root.appending(path: "ran.marker")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            server = try MiniHTTPServer(bodies: bodies)
            try await server.start()
        }

        func script(version: String) -> Data {
            Data("#!/bin/sh\ntouch '\(marker.path(percentEncoded: false))'\necho \(version)\n".utf8)
        }

        func serve(_ binary: Data, name: String = "yt-dlp_macos", sumsFor digest: Data? = nil) {
            server.setBody(binary, for: "/\(name)")
            let hex = Self.sha256(digest ?? binary)
            server.setBody(Data("\(hex)  other_file\n\(hex)  \(name)\n".utf8), for: "/SHA2-256SUMS")
        }

        func source(name: String = "yt-dlp_macos", archive: Bool = false) -> ToolSource {
            ToolSource(binaryURL: server.url(path: "/\(name)"), checksumURL: server.url(path: "/SHA2-256SUMS"),
                       checksumEntryName: name, archive: archive)
        }

        func installer() -> ToolInstaller {
            ToolInstaller(tools: tools, session: .shared, defaults: defaults, ytdlpSource: source())
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        func cleanup() {
            server.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func installsVerifiedBinary() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "2026.01.01"))
        let progress = ProgressLog()
        let location = try await env.installer().install(.ytdlp, from: env.source()) { progress.add($0) }
        #expect(location.source == .managed)
        #expect(env.tools.locate(.ytdlp)?.source == .managed)
        #expect(await env.tools.version(.ytdlp) == "2026.01.01")
        let attrs = try FileManager.default.attributesOfItem(atPath: location.url.path(percentEncoded: false))
        #expect((attrs[.posixPermissions] as? Int) == 0o755)
        #expect(progress.values.last == 1.0)
        let staging = env.managed.appending(path: ".staging")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []
        #expect(left.isEmpty)
        let stagingAttrs = try FileManager.default.attributesOfItem(atPath: staging.path(percentEncoded: false))
        #expect((stagingAttrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func wrongChecksumFailsWithoutExecuting() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "2026.01.01"), sumsFor: Data("something else".utf8))
        await #expect(throws: MediaError.installFailed("checksum mismatch")) {
            try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        }
        #expect(env.tools.locate(.ytdlp) == nil)
        #expect(!FileManager.default.fileExists(atPath: env.managed.appending(path: "yt-dlp").path(percentEncoded: false)))
        let staging = env.managed.appending(path: ".staging")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path(percentEncoded: false)))
    }

    @Test func missingChecksumEntryFails() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1"))
        let bad = ToolSource(binaryURL: env.server.url(path: "/yt-dlp_macos"), checksumURL: env.server.url(path: "/SHA2-256SUMS"),
                             checksumEntryName: "nope", archive: false)
        await #expect(throws: MediaError.self) { try await env.installer().install(.ytdlp, from: bad) { _ in } }
        #expect(env.tools.locate(.ytdlp) == nil)
    }

    @Test func updateReplacesAndFailedUpdateKeepsOld() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        _ = try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        #expect(await env.tools.version(.ytdlp) == "1.0")

        // A corrupt update leaves the old version in place and working.
        env.serve(env.script(version: "2.0"), sumsFor: Data("bad".utf8))
        await #expect(throws: MediaError.installFailed("checksum mismatch")) {
            try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        }
        #expect(await env.tools.version(.ytdlp) == "1.0")

        // A checksum-valid but broken binary also keeps the old one.
        env.serve(Data("#!/bin/sh\nexit 3\n".utf8))
        await #expect(throws: MediaError.self) { try await env.installer().install(.ytdlp, from: env.source()) { _ in } }
        #expect(await env.tools.version(.ytdlp) == "1.0")

        env.serve(env.script(version: "2.0"))
        _ = try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        #expect(await env.tools.version(.ytdlp) == "2.0")
        let mode = try FileManager.default.attributesOfItem(atPath: env.managed.appending(path: "yt-dlp").path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func updateIfDueRunsAtMostOncePerDay() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        _ = try await installer.install(.ytdlp, from: env.source()) { _ in }
        let baseline = env.server.requestedPaths.count

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        env.serve(env.script(version: "2.0"))
        await installer.updateIfDue(now: t0)
        #expect(env.server.requestedPaths.count == baseline + 2)
        #expect(await env.tools.version(.ytdlp) == "2.0")
        await installer.updateIfDue(now: t0.addingTimeInterval(3600))
        #expect(env.server.requestedPaths.count == baseline + 2)
        // A day later the release is unchanged: only SHA2-256SUMS is fetched (the managed copy already matches it).
        await installer.updateIfDue(now: t0.addingTimeInterval(25 * 3600))
        #expect(env.server.requestedPaths.count == baseline + 3)
        #expect(env.server.requestedPaths.last == "/SHA2-256SUMS")
    }

    @Test func updateNowReinstallsAndRecordsTheCheck() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let installer = ToolInstaller(tools: env.tools, session: .shared, defaults: env.defaults, ytdlpSource: env.source(), now: { now })
        _ = try await installer.install(.ytdlp, from: env.source()) { _ in }
        #expect(installer.lastUpdateCheck == nil)
        env.serve(env.script(version: "2.0"))
        let progress = ProgressLog()
        let location = try await installer.updateNow { progress.add($0) }
        #expect(location.source == .managed)
        #expect(await env.tools.version(.ytdlp) == "2.0")
        #expect(installer.lastUpdateCheck == now)
        #expect(progress.values.last == 1.0)
        #expect(installer.installBackoffRemaining(.ytdlp) == nil)
    }

    @Test func failedUpdateNowKeepsOldAndBacksOff() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        _ = try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        let offline = ToolSource(binaryURL: URL(string: "http://127.0.0.1:1/yt-dlp_macos")!,
                                 checksumURL: URL(string: "http://127.0.0.1:1/SHA2-256SUMS")!, checksumEntryName: "yt-dlp_macos", archive: false)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let failing = ToolInstaller(tools: env.tools, session: .shared, defaults: env.defaults, ytdlpSource: offline, now: { t0 })
        await #expect(throws: MediaError.self) { try await failing.updateNow { _ in } }
        #expect(await env.tools.version(.ytdlp) == "1.0")
        #expect(failing.lastUpdateCheck == nil)
        #expect(failing.installBackoffRemaining(.ytdlp) == 600)
        let later = ToolInstaller(tools: env.tools, session: .shared, defaults: env.defaults, ytdlpSource: offline,
                                  now: { t0.addingTimeInterval(240) })
        #expect(later.installBackoffRemaining(.ytdlp) == 360)
        let after = ToolInstaller(tools: env.tools, session: .shared, defaults: env.defaults, ytdlpSource: offline,
                                  now: { t0.addingTimeInterval(601) })
        #expect(after.installBackoffRemaining(.ytdlp) == nil)
    }

    @Test func updateNowDuringTheDailyCheckDownloadsOnce() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        _ = try await installer.install(.ytdlp, from: env.source()) { _ in }
        let baseline = env.server.requestedPaths.count
        // The new build's start check takes half a second, so the two calls overlap.
        env.serve(Data("#!/bin/sh\nsleep 0.5\necho 2.0\n".utf8))
        async let check: Void = installer.updateIfDue(now: Date())
        async let update = installer.updateNow { _ in }
        _ = try await (check, update)
        #expect(Array(env.server.requestedPaths.dropFirst(baseline)) == ["/SHA2-256SUMS", "/yt-dlp_macos"])
        #expect(await env.tools.version(.ytdlp) == "2.0")
        #expect(installer.lastUpdateCheck != nil)
    }

    @Test func updateIfDueSkipsWhenNothingManaged() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        await env.installer().updateIfDue(now: Date())
        #expect(env.server.requestedPaths.isEmpty)
        #expect(env.tools.locate(.ytdlp) == nil)
    }

    @Test func installsFromZipArchiveWithNestedFolder() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let build = env.root.appending(path: "build/inner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let tool = build.appending(path: "ffmpeg")
        try Data("#!/bin/sh\necho ffmpeg version 9.9\n".utf8).write(to: tool)
        let zip = env.root.appending(path: "ffmpeg.zip")
        let ditto = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                ["-c", "-k", "--keepParent", env.root.appending(path: "build").path(percentEncoded: false),
                                                 zip.path(percentEncoded: false)], timeout: 30)
        #expect(ditto.status == 0)
        env.serve(try Data(contentsOf: zip), name: "ffmpeg.zip")
        let location = try await env.installer().install(.ffmpeg, from: env.source(name: "ffmpeg.zip", archive: true)) { _ in }
        #expect(location.url.lastPathComponent == "ffmpeg")
        #expect(await env.tools.version(.ffmpeg) == "ffmpeg version 9.9")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.managed.appending(path: ".staging").path(percentEncoded: false))) ?? []).isEmpty)
    }

    @Test func ensureReturnsExistingWithoutDownloading() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        _ = try await installer.ensure(.ytdlp)
        let n = env.server.requestedPaths.count
        #expect(n == 2)
        _ = try await installer.ensure(.ytdlp)
        #expect(env.server.requestedPaths.count == n)
    }

    @Test func concurrentEnsureDownloadsOnce() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        async let a = installer.ensure(.ytdlp)
        async let b = installer.ensure(.ytdlp)
        let (first, second) = try await (a, b)
        #expect(first == second)
        #expect(env.server.requestedPaths.filter { $0 == "/yt-dlp_macos" }.count == 1)
        #expect(await env.tools.version(.ytdlp) == "1.0")
    }

    @Test func homebrewToolIsNeverTouched() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let brew = env.root.appending(path: "brew", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: brew, withIntermediateDirectories: true)
        let tool = brew.appending(path: "yt-dlp")
        try env.script(version: "brew-1").write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        let before = try Data(contentsOf: tool)
        env.serve(env.script(version: "managed"))
        let installer = ToolInstaller(tools: MediaTools(managedFolder: env.managed, homebrewFolders: [brew]), session: .shared,
                                      defaults: env.defaults, ytdlpSource: env.source())
        await installer.updateIfDue(now: Date())
        #expect(env.server.requestedPaths.isEmpty)
        let found = try await installer.ensure(.ytdlp)
        #expect(found.source == .homebrew && found.url == tool)
        #expect(env.server.requestedPaths.isEmpty)
        #expect(try Data(contentsOf: tool) == before)
        #expect(!FileManager.default.fileExists(atPath: env.managed.appending(path: "yt-dlp").path(percentEncoded: false)))
    }

    @Test func failedCheckIsNotRecordedAndRetries() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        _ = try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        env.serve(env.script(version: "2.0"))
        let offline = ToolSource(binaryURL: URL(string: "http://127.0.0.1:1/yt-dlp_macos")!,
                                 checksumURL: URL(string: "http://127.0.0.1:1/SHA2-256SUMS")!, checksumEntryName: "yt-dlp_macos", archive: false)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await ToolInstaller(tools: env.tools, session: .shared, defaults: env.defaults, ytdlpSource: offline).updateIfDue(now: now)
        #expect(env.defaults.object(forKey: "mediaToolsLastUpdateCheck") == nil)
        #expect(await env.tools.version(.ytdlp) == "1.0")
        await env.installer().updateIfDue(now: now.addingTimeInterval(60))
        #expect(await env.tools.version(.ytdlp) == "2.0")
        #expect(env.defaults.object(forKey: "mediaToolsLastUpdateCheck") as? Date == now.addingTimeInterval(60))
    }

    @Test func concurrentUpdateChecksRunOnce() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        _ = try await installer.install(.ytdlp, from: env.source()) { _ in }
        let baseline = env.server.requestedPaths.count
        env.serve(env.script(version: "2.0"))             // a new release, so the check really downloads
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        async let a: Void = installer.updateIfDue(now: now)
        async let b: Void = installer.updateIfDue(now: now)
        _ = await (a, b)
        #expect(env.server.requestedPaths.count == baseline + 2)
    }

    @Test func staleStagingFoldersAreRemoved() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let staging = env.managed.appending(path: ".staging", directoryHint: .isDirectory)
        let old = staging.appending(path: "old"), fresh = staging.appending(path: "fresh")
        for dir in [old, fresh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path(percentEncoded: false))
        _ = try await env.installer().install(.ytdlp, from: env.source()) { _ in }
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    }

    @Test func missingChecksumEntryCleansUpAndNeverRuns() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1"))
        let bad = ToolSource(binaryURL: env.server.url(path: "/yt-dlp_macos"), checksumURL: env.server.url(path: "/SHA2-256SUMS"),
                             checksumEntryName: "nope", archive: false)
        await #expect(throws: MediaError.self) { try await env.installer().install(.ytdlp, from: bad) { _ in } }
        let staging = env.managed.appending(path: ".staging")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path(percentEncoded: false)))
    }

    @Test func checksumParser() throws {
        let hex = String(repeating: "ab", count: 32)
        func parse(_ text: String, _ entry: String = "tool") throws -> String? {
            let f = TestTemp.root.appending(path: "sums-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: f) }
            try Data(text.utf8).write(to: f)
            return ToolInstaller.checksum(in: f, entry: entry)
        }
        #expect(try parse("\(hex.uppercased())  tool\n") == hex)
        #expect(try parse("\(hex) *tool\n") == hex)
        #expect(try parse("\(hex)  other\r\n\(hex)  tool\r\n") == hex)
        #expect(try parse("\(hex)  other\n") == nil)
        #expect(try parse("\(hex)  tool\n\(String(repeating: "cd", count: 32))  tool\n") == nil)
        #expect(try parse("\(hex)  tool\n\(hex)  tool\n") == hex)
        #expect(try parse("nothex  tool\n") == nil)
    }

    @Test func pinnedSourcesAreChecksummedHTTPS() {
        #expect(ToolSource.ytdlp.binaryURL.absoluteString == "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")
        #expect(ToolSource.ytdlp.checksumEntryName == "yt-dlp_macos")
        for arch in [ToolSource.Arch.arm64, .x86_64] {
            let s = ToolSource.ffmpeg(arch: arch)
            #expect(s.binaryURL.scheme == "https" && s.checksumURL.scheme == "https")
            #expect(s.archive && s.checksumEntryName == "ffmpeg.zip")
        }
        #expect(ToolSource.ffmpeg(arch: .arm64).binaryURL.absoluteString.contains("/arm64/"))
        #expect(ToolSource.ffmpeg(arch: .x86_64).binaryURL.absoluteString.contains("/amd64/"))
    }

    // MARK: Pinned digests (I7)

    @Test func ffmpegSourcesCarryTheirPinnedDigests() {
        #expect(ToolSource.ffmpeg(arch: .arm64).expectedSHA256 == "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924")
        #expect(ToolSource.ffmpeg(arch: .x86_64).expectedSHA256 == "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4")
        #expect(ToolSource.ytdlp.expectedSHA256 == nil)            // "latest" moves; its published SUMS is the check
    }

    @Test func pinnedDigestMismatchRefusesToInstall() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1"))                       // the published checksum matches the download…
        var source = env.source()
        source.expectedSHA256 = String(repeating: "0", count: 64)  // …but the pinned one doesn't
        await #expect(throws: MediaError.installFailed("checksum mismatch")) {
            try await env.installer().install(.ytdlp, from: source) { _ in }
        }
        #expect(env.tools.locate(.ytdlp) == nil)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path(percentEncoded: false)))
    }

    @Test func publishedChecksumMustAgreeWithThePin() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let binary = env.script(version: "1")
        env.serve(binary, sumsFor: Data("other".utf8))
        var source = env.source()
        source.expectedSHA256 = Env.sha256(binary)
        await #expect(throws: MediaError.installFailed("checksum mismatch")) {
            try await env.installer().install(.ytdlp, from: source) { _ in }
        }
        #expect(env.tools.locate(.ytdlp) == nil)
    }

    @Test func matchingPinInstalls() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let binary = env.script(version: "1")
        env.serve(binary)
        var source = env.source()
        source.expectedSHA256 = Env.sha256(binary).uppercased()
        let location = try await env.installer().install(.ytdlp, from: source) { _ in }
        #expect(location.source == .managed)
    }

    // MARK: Daily update reads the checksums first (M3)

    @Test func dailyUpdateSkipsTheDownloadWhenTheManagedCopyMatches() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        _ = try await installer.install(.ytdlp, from: env.source()) { _ in }
        try? FileManager.default.removeItem(at: env.marker)
        let baseline = env.server.requestedPaths.count
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await installer.updateIfDue(now: now)
        #expect(Array(env.server.requestedPaths.dropFirst(baseline)) == ["/SHA2-256SUMS"])
        #expect(installer.lastUpdateCheck == now)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path(percentEncoded: false)))   // nothing new was run
        #expect(await env.tools.version(.ytdlp) == "1.0")
    }

    @Test func dailyUpdateFetchesTheChecksumsBeforeANewBinary() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.serve(env.script(version: "1.0"))
        let installer = env.installer()
        _ = try await installer.install(.ytdlp, from: env.source()) { _ in }
        let baseline = env.server.requestedPaths.count
        env.serve(env.script(version: "2.0"))
        await installer.updateIfDue(now: Date())
        #expect(Array(env.server.requestedPaths.dropFirst(baseline)) == ["/SHA2-256SUMS", "/yt-dlp_macos"])
        #expect(await env.tools.version(.ytdlp) == "2.0")
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ v: Double) { lock.withLock { stored.append(v) } }
    var values: [Double] { lock.withLock { stored } }
}
