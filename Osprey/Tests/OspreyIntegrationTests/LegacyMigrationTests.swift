import Foundation
import OspreyBridge
import Testing
@testable import OspreyIntegration

/// The one-time import of Slipstream's data, run against a temporary home folder and throwaway defaults domains.
@Suite struct LegacyMigrationTests {
    /// A temporary home with Slipstream's data laid out the way the old app left it.
    final class Fixture {
        let home: URL
        let legacyDomain = "osprey-tests-legacy-\(UUID().uuidString)"
        let domain = "osprey-tests-new-\(UUID().uuidString)"
        let legacy: UserDefaults
        let defaults: UserDefaults

        init() throws {
            home = FileManager.default.temporaryDirectory.appending(path: "osprey-tests-home-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            legacy = try #require(UserDefaults(suiteName: legacyDomain))
            defaults = try #require(UserDefaults(suiteName: domain))
        }

        deinit {
            legacy.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: home)
            // cfprefsd leaves an empty plist behind for each throwaway domain.
            let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
            for name in [legacyDomain, domain] { try? FileManager.default.removeItem(at: preferences.appending(path: "\(name).plist")) }
        }

        var migration: LegacyMigration { LegacyMigration(home: home, defaults: defaults, domain: domain, legacyDomain: legacyDomain) }
        func path(_ relative: String) -> String { (home.path(percentEncoded: false) as NSString).appendingPathComponent(relative) }
        var legacySupport: URL { home.appending(path: "Library/Application Support/Slipstream", directoryHint: .isDirectory) }
        var support: URL { home.appending(path: "Library/Application Support/Osprey", directoryHint: .isDirectory) }

        func write(_ text: String, to url: URL, executable: Bool = false) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
            }
        }

        /// What Slipstream left: settings, media choices, the managed yt-dlp, a staging leftover and a run lock.
        func seedLegacy() throws {
            legacy.set("de", forKey: "media.audioLanguage")
            legacy.set("fr", forKey: "media.subtitleLanguage")
            legacy.set(true, forKey: "media.subtitleIsAuto")
            legacy.set(720, forKey: "media.maxHeight")
            legacy.set(12, forKey: "maxConnections")
            legacy.set("Dark", forKey: "appearance")
            legacy.set(true, forKey: "didShowSafariSetup")
            legacy.set(Data(#"{"enabled":true,"extensions":["zip"],"captureInPrivate":false}"#.utf8), forKey: "integrationSettings")
            legacy.set(Date(timeIntervalSince1970: 1_800_000_000), forKey: "mediaToolsLastUpdateCheck")
            try write("yt-dlp binary", to: legacySupport.appending(path: "Tools/yt-dlp"), executable: true)
            try write("ffmpeg binary", to: legacySupport.appending(path: "Tools/ffmpeg"), executable: true)
            try write("half a download", to: legacySupport.appending(path: "Tools/.staging/partial"))
            try write("", to: legacySupport.appending(path: "run/123.lock"))
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    }

    @Test func copiesSettingsAndToolsOnceAndLeavesTheOldDataInPlace() throws {
        let f = try Fixture()
        try f.seedLegacy()

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(!outcome.alreadyDone)
        #expect(f.defaults.string(forKey: "media.audioLanguage") == "de")
        #expect(f.defaults.string(forKey: "media.subtitleLanguage") == "fr")
        #expect(f.defaults.bool(forKey: "media.subtitleIsAuto"))
        #expect(f.defaults.integer(forKey: "media.maxHeight") == 720)
        #expect(f.defaults.integer(forKey: "maxConnections") == 12)
        #expect(f.defaults.string(forKey: "appearance") == "Dark")
        #expect(f.defaults.data(forKey: "integrationSettings") == f.legacy.data(forKey: "integrationSettings"))
        #expect(f.defaults.object(forKey: "mediaToolsLastUpdateCheck") as? Date == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))

        // The tools arrive with their bytes and their executable bit; staging leftovers and run locks don't.
        let ytdlp = f.support.appending(path: "Tools/yt-dlp")
        #expect(try Data(contentsOf: ytdlp) == Data("yt-dlp binary".utf8))
        #expect(FileManager.default.isExecutableFile(atPath: ytdlp.path(percentEncoded: false)))
        #expect(FileManager.default.isExecutableFile(atPath: f.support.appending(path: "Tools/ffmpeg").path(percentEncoded: false)))
        #expect(!f.exists(f.support.appending(path: "Tools/.staging")))
        #expect(!f.exists(f.support.appending(path: "run")))
        #expect(outcome.copiedFiles == ["Tools/ffmpeg", "Tools/yt-dlp"])

        // Copied, not moved.
        #expect(f.exists(f.legacySupport.appending(path: "Tools/yt-dlp")))
        #expect(f.legacy.string(forKey: "media.audioLanguage") == "de")
    }

    @Test func keepsCustomPathsAndRewritesOldDefaultPaths() throws {
        let f = try Fixture()
        let custom = "/Volumes/Media/Slipstream Videos/"
        let customMusic = f.path("Music/Slipstream")
        f.legacy.set(custom, forKey: "media.videoFolder")
        f.legacy.set(customMusic, forKey: "media.audioFolder")
        f.legacy.set(f.path("Library/Application Support/Slipstream/Tools"), forKey: "toolsFolder")
        f.legacy.set(f.path("Library/Application Support/Slipstream") + "/", forKey: "supportFolder")
        f.legacy.set(f.path("Library/Group Containers/8CG9QYMSR5.com.akhanlari.slipstream/bridge.sock"), forKey: "socket")
        f.legacy.set([f.path("Library/Application Support/Slipstream/Tools/yt-dlp"), "/opt/homebrew/bin/yt-dlp"], forKey: "toolPaths")
        f.legacy.set(f.path("Library/Application Support/SlipstreamExtras"), forKey: "lookalike")

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(f.defaults.string(forKey: "media.videoFolder") == custom)
        #expect(f.defaults.string(forKey: "media.audioFolder") == customMusic)
        #expect(f.defaults.string(forKey: "toolsFolder") == f.path("Library/Application Support/Osprey/Tools"))
        #expect(f.defaults.string(forKey: "supportFolder") == f.path("Library/Application Support/Osprey") + "/")
        #expect(f.defaults.string(forKey: "socket") == f.path("Library/Group Containers/8CG9QYMSR5.com.akhanlari.osprey/bridge.sock"))
        #expect(f.defaults.stringArray(forKey: "toolPaths") == [f.path("Library/Application Support/Osprey/Tools/yt-dlp"), "/opt/homebrew/bin/yt-dlp"])
        #expect(f.defaults.string(forKey: "lookalike") == f.path("Library/Application Support/SlipstreamExtras"))
        #expect(outcome.rewrittenKeys.sorted() == ["socket", "supportFolder", "toolPaths", "toolsFolder"])
    }

    @Test func doesNotRunTwice() throws {
        let f = try Fixture()
        try f.seedLegacy()
        #expect(f.migration.run().failures.isEmpty)

        // Osprey is used, then something changes on the old side; a second launch must not import it.
        f.defaults.set("ja", forKey: "media.audioLanguage")
        f.legacy.set("it", forKey: "media.audioLanguage")
        f.legacy.set("new", forKey: "laterKey")
        try f.write("newer", to: f.legacySupport.appending(path: "Tools/later-tool"))
        try f.write("legacy", to: f.home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.akhanlari.slipstream.host.json"))

        let second = f.migration.run()

        #expect(second.alreadyDone)
        #expect(second == LegacyMigration.Outcome(alreadyDone: true))
        #expect(f.defaults.string(forKey: "media.audioLanguage") == "ja")
        #expect(f.defaults.object(forKey: "laterKey") == nil)
        #expect(!f.exists(f.support.appending(path: "Tools/later-tool")))
        #expect(f.exists(f.home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.akhanlari.slipstream.host.json")))
    }

    @Test func keepsOspreysOwnValuesAndFillsInOnlyWhatIsMissing() throws {
        let f = try Fixture()
        try f.seedLegacy()
        f.defaults.set("es", forKey: "media.audioLanguage")
        try f.write("osprey's own", to: f.support.appending(path: "Tools/yt-dlp"), executable: true)

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(!outcome.copiedKeys.contains("media.audioLanguage"))
        #expect(f.defaults.string(forKey: "media.audioLanguage") == "es")
        #expect(f.defaults.string(forKey: "media.subtitleLanguage") == "fr")
        #expect(try Data(contentsOf: f.support.appending(path: "Tools/yt-dlp")) == Data("osprey's own".utf8))
        #expect(outcome.copiedFiles == ["Tools/ffmpeg"])
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))
    }

    @Test func removesOnlyTheOldNativeHostManifests() throws {
        let f = try Fixture()
        let support = f.home.appending(path: "Library/Application Support")
        let oldChrome = support.appending(path: "Google/Chrome/NativeMessagingHosts/com.akhanlari.slipstream.host.json")
        let oldEdge = support.appending(path: "Microsoft Edge/NativeMessagingHosts/com.akhanlari.slipstream.host.json")
        let newChrome = support.appending(path: "Google/Chrome/NativeMessagingHosts/\(BridgeLocation.nativeHostName).json")
        let other = support.appending(path: "Google/Chrome/NativeMessagingHosts/com.example.other.json")
        for url in [oldChrome, oldEdge, newChrome, other] { try f.write("{}", to: url) }

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(!f.exists(oldChrome) && !f.exists(oldEdge))
        #expect(f.exists(newChrome) && f.exists(other))
        #expect(Set(outcome.removedManifests.map(\.lastPathComponent)) == ["com.akhanlari.slipstream.host.json"])
        #expect(outcome.removedManifests.count == 2)
    }

    @Test func withNothingToImportItOnlyRecordsThatItRan() throws {
        let f = try Fixture()

        let outcome = f.migration.run()

        #expect(outcome == LegacyMigration.Outcome())
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))
        #expect(!f.exists(f.support))
        #expect(f.migration.run().alreadyDone)
    }

    @Test func aFailedCopyIsRetriedOnTheNextLaunch() throws {
        let f = try Fixture()
        try f.seedLegacy()
        // A file where Osprey's Application Support folder should be: the copy can't create it.
        try f.write("in the way", to: f.home.appending(path: "Library/Application Support/Osprey"))

        let first = f.migration.run()
        #expect(!first.failures.isEmpty)
        #expect(!f.defaults.bool(forKey: LegacyMigration.doneKey))
        #expect(f.defaults.string(forKey: "media.audioLanguage") == "de")   // the settings still came over

        try FileManager.default.removeItem(at: f.home.appending(path: "Library/Application Support/Osprey"))
        let second = f.migration.run()
        #expect(second.failures.isEmpty)
        #expect(second.copiedKeys.isEmpty)   // every setting is already there: none is written again
        #expect(second.copiedFiles == ["Tools/ffmpeg", "Tools/yt-dlp"])
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))
    }

    // MARK: Review fixes

    /// The renamed Safari extension starts switched off, so an upgrader must see the setup prompt again.
    @Test func neverCopiesTheSafariSetupFlag() throws {
        let f = try Fixture()
        try f.seedLegacy()

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(f.defaults.object(forKey: "didShowSafariSetup") == nil)
        #expect(!outcome.copiedKeys.contains("didShowSafariSetup"))
        #expect(f.legacy.bool(forKey: "didShowSafariSetup"))            // the old value is left alone
        #expect(f.defaults.string(forKey: "media.subtitleLanguage") == "fr")
    }

    /// A copy that a crash cut short lives only under a hidden temporary name: the tool's own path never holds a
    /// partial file, and the next run deletes the temporary and copies the tool whole.
    @Test func anInterruptedCopyNeverLeavesACutOffToolBehind() throws {
        let f = try Fixture()
        try f.seedLegacy()
        let tools = f.support.appending(path: "Tools", directoryHint: .isDirectory)
        let stale = tools.appending(path: ".yt-dlp.osprey-import-\(UUID().uuidString)")
        try f.write("yt-dl", to: stale, executable: true)                    // cut off mid-copy
        let unrelated = tools.appending(path: ".yt-dlp.osprey-import-notes")
        try f.write("not ours", to: unrelated)

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(!f.exists(stale))
        #expect(f.exists(unrelated))                                         // only the exact temporary pattern goes
        let ytdlp = tools.appending(path: "yt-dlp")
        #expect(try Data(contentsOf: ytdlp) == Data("yt-dlp binary".utf8))
        #expect(FileManager.default.isExecutableFile(atPath: ytdlp.path(percentEncoded: false)))
        let names = try FileManager.default.contentsOfDirectory(atPath: tools.path(percentEncoded: false))
        #expect(names.filter { $0.contains(".osprey-import-") } == [".yt-dlp.osprey-import-notes"])
    }

    @Test func anAtomicCopyNeverReplacesAFileThatAppearedMeanwhile() throws {
        let f = try Fixture()
        let source = f.home.appending(path: "source")
        let destination = f.home.appending(path: "dest/tool")
        try f.write("new", to: source)
        try f.write("already there", to: destination)

        #expect(try f.migration.copyAtomically(source, to: destination) == false)
        #expect(try Data(contentsOf: destination) == Data("already there".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path(percentEncoded: false)) == ["tool"])

        let fresh = f.home.appending(path: "dest/other")
        #expect(try f.migration.copyAtomically(source, to: fresh))
        #expect(try Data(contentsOf: fresh) == Data("new".utf8))
    }

    /// A run that stopped half way (some settings and one tool copied, no done marker) resumes: it fills in the rest,
    /// keeps what is there, and only then records that it is done.
    @Test func aHalfFinishedMigrationResumes() throws {
        let f = try Fixture()
        try f.seedLegacy()
        f.defaults.set("de", forKey: "media.audioLanguage")                   // copied before the interruption
        f.defaults.set(1080, forKey: "media.maxHeight")                      // and since changed in Osprey
        try f.write("yt-dlp binary", to: f.support.appending(path: "Tools/yt-dlp"), executable: true)
        #expect(!f.defaults.bool(forKey: LegacyMigration.doneKey))

        let outcome = f.migration.run()

        #expect(outcome.failures.isEmpty)
        #expect(!outcome.alreadyDone)
        #expect(f.defaults.integer(forKey: "media.maxHeight") == 1080)
        #expect(f.defaults.string(forKey: "media.subtitleLanguage") == "fr")
        #expect(f.defaults.integer(forKey: "maxConnections") == 12)
        #expect(!outcome.copiedKeys.contains("media.audioLanguage") && !outcome.copiedKeys.contains("media.maxHeight"))
        #expect(outcome.copiedFiles == ["Tools/ffmpeg"])
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))
        #expect(f.migration.run().alreadyDone)
    }

    // MARK: Retries

    /// A step that keeps failing is tried on three launches, then given up; the migration is then done for good.
    @Test func aFailingStepIsGivenUpAfterThreeAttempts() throws {
        let f = try Fixture()
        try f.seedLegacy()
        // A file where Osprey's Application Support folder should be, for good: the files step can never succeed.
        try f.write("in the way", to: f.home.appending(path: "Library/Application Support/Osprey"))

        let first = f.migration.run()
        #expect(!first.failures.isEmpty && first.gaveUp.isEmpty)
        #expect(f.defaults.bool(forKey: LegacyMigration.Step.settings.doneKey))
        #expect(f.defaults.bool(forKey: LegacyMigration.Step.manifests.doneKey))
        #expect(!f.defaults.bool(forKey: LegacyMigration.doneKey))

        let second = f.migration.run()
        #expect(second.gaveUp.isEmpty && second.copiedKeys.isEmpty)    // finished steps don't run again
        #expect(!f.defaults.bool(forKey: LegacyMigration.doneKey))

        let third = f.migration.run()
        #expect(third.gaveUp == [.files])
        #expect(third.summary.contains("gave up after 3 attempts on: files"))
        #expect(f.defaults.integer(forKey: LegacyMigration.Step.files.attemptsKey) == 3)
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))

        #expect(f.migration.run().alreadyDone)
    }

    /// Once a step (or a file) is done, what the app or the user removes afterwards stays removed, even though another
    /// step is still being retried.
    @Test func aRetryNeverBringsBackWhatWasRemovedSince() throws {
        let f = try Fixture()
        try f.seedLegacy()
        let legacyFFmpeg = f.legacySupport.appending(path: "Tools/ffmpeg")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: legacyFFmpeg.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyFFmpeg.path(percentEncoded: false)) }

        let first = f.migration.run()
        #expect(first.copiedFiles == ["Tools/yt-dlp"])                  // ffmpeg can't be read yet
        #expect(first.failures.count == 1)
        #expect(f.defaults.string(forKey: "media.audioLanguage") == "de")

        // Later the app or the user removes a copied setting and the copied yt-dlp.
        f.defaults.removeObject(forKey: "media.audioLanguage")
        try FileManager.default.removeItem(at: f.support.appending(path: "Tools/yt-dlp"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyFFmpeg.path(percentEncoded: false))

        let second = f.migration.run()
        #expect(second.failures.isEmpty)
        #expect(second.copiedFiles == ["Tools/ffmpeg"])
        #expect(second.copiedKeys.isEmpty)
        #expect(f.defaults.object(forKey: "media.audioLanguage") == nil)
        #expect(!f.exists(f.support.appending(path: "Tools/yt-dlp")))
        #expect(f.defaults.bool(forKey: LegacyMigration.doneKey))
    }

    @Test func theAppUsesTheOldAndNewIdentifiers() {
        let migration = LegacyMigration(home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        #expect(LegacyMigration.legacyDefaultsDomain == "com.akhanlari.slipstream")
        #expect(BridgeLocation.appBundleID == "com.akhanlari.osprey")
        #expect(migration.legacySupportPath == "/Users/someone/Library/Application Support/Slipstream")
        #expect(migration.supportPath == "/Users/someone/Library/Application Support/Osprey")
        #expect(migration.movedPath("/Users/someone/Library/Application Support/Slipstream/Tools/ffmpeg")
                == "/Users/someone/Library/Application Support/Osprey/Tools/ffmpeg")
        #expect(migration.movedPath("/Users/someone/Downloads/Slipstream") == nil)
    }
}
