import Foundation
import Testing
@testable import OspreyMedia

/// The one-time sweep of the former app's (Slipstream's) crash leftovers: the same rules as Osprey's own sweep, with
/// that app's names and mark, and never while that app runs.
@Suite struct LegacyLeftoversTests {
    private struct Layout {
        let root = TestTemp.root.appending(path: "osprey-tests-legacy-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        var temp: URL { root.appending(path: "tmp", directoryHint: .isDirectory) }
        var video: URL { root.appending(path: "Video", directoryHint: .isDirectory) }
        var music: URL { root.appending(path: "Music", directoryHint: .isDirectory) }
        var elsewhere: URL { root.appending(path: "Elsewhere", directoryHint: .isDirectory) }
        var run: URL { root.appending(path: "Slipstream/run", directoryHint: .isDirectory) }

        func dir(_ url: URL, age: TimeInterval = 3600) throws -> URL {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try setAge(url, age)
            return url
        }

        func file(_ url: URL, age: TimeInterval = 3600, mark: String? = nil) throws -> URL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            if let mark {
                let value = Array("1".utf8)
                #expect(setxattr(url.path(percentEncoded: false), mark, value, value.count, 0, XATTR_NOFOLLOW) == 0)
            }
            try setAge(url, age)
            return url
        }

        func setAge(_ url: URL, _ age: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    private func uuid() -> String { UUID().uuidString }
    private let oldMark = "com.akhanlari.slipstream.partial"

    @Test func sweepsOnlyTheFormerAppsMarkedLeftoversInTheUsualPlaces() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        // Removed: the former app's marked merges, part folders holding only parts, and cookie folders.
        let oldPartial = try l.file(l.video.appending(path: "Clip [a].slipstream-partial.mp4"), mark: oldMark)
        let oldPartialMP3 = try l.file(l.music.appending(path: "My List/Song [b].slipstream-partial.mp3"), mark: oldMark)
        let oldHidden = try l.dir(l.video.appending(path: ".slipstream-media-\(uuid())"))
        _ = try l.file(oldHidden.appending(path: "video.mp4.slpart")); _ = try l.file(oldHidden.appending(path: "audio.m4a"))
        try l.setAge(oldHidden, 3600)
        let oldCookies = try l.dir(l.temp.appending(path: "slipstream-cookies-\(uuid())"))
        _ = try l.file(oldCookies.appending(path: "cookies.txt")); try l.setAge(oldCookies, 3600)

        // Kept: unmarked or wrongly marked names, the user's files, fresh items, Osprey's own, and anything elsewhere.
        let unmarked = try l.file(l.video.appending(path: "Other [c].slipstream-partial.mp4"))
        let ospreyMarked = try l.file(l.video.appending(path: "Mixed [d].slipstream-partial.mp4"), mark: MediaCleanup.partialAttribute)
        let fresh = try l.file(l.video.appending(path: "New [e].slipstream-partial.mkv"), age: -60, mark: oldMark)
        let userFile = try l.file(l.video.appending(path: "Report.partial.pdf"), mark: oldMark)
        let ospreyPartial = try l.file(l.video.appending(path: "Ours [f].osprey-partial.mp4"), mark: MediaCleanup.partialAttribute)
        let mixedHidden = try l.dir(l.video.appending(path: ".slipstream-media-\(uuid())"))
        let keepNote = try l.file(mixedHidden.appending(path: "notes.txt")); try l.setAge(mixedHidden, 3600)
        let oddHidden = try l.dir(l.video.appending(path: ".slipstream-media-notes"))
        let crowdedCookies = try l.dir(l.temp.appending(path: "slipstream-cookies-\(uuid())"))
        let crowdedNote = try l.file(crowdedCookies.appending(path: "other.txt")); try l.setAge(crowdedCookies, 3600)
        let elsewhere = try l.file(l.elsewhere.appending(path: "Clip.slipstream-partial.mp4"), mark: oldMark)
        let deep = try l.file(l.video.appending(path: "A/B/Deep.slipstream-partial.mp4"), mark: oldMark)

        let removed = try #require(LegacyLeftovers.sweep(in: [l.video, l.music], temporaryFolder: l.temp, olderThan: Date(),
                                                         legacyRunFolder: l.run, legacyAppRunning: false))

        for gone in [oldPartial, oldPartialMP3, oldHidden, oldCookies] { #expect(!exists(gone), "\(gone.lastPathComponent) should go") }
        for kept in [unmarked, ospreyMarked, fresh, userFile, ospreyPartial, mixedHidden, keepNote, oddHidden, crowdedCookies,
                     crowdedNote, elsewhere, deep] {
            #expect(exists(kept), "\(kept.lastPathComponent) should be kept")
        }
        #expect(removed.count == 4)
    }

    @Test func nothingIsTouchedWhileTheFormerAppRuns() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let oldPartial = try l.file(l.video.appending(path: "Clip [a].slipstream-partial.mp4"), mark: oldMark)
        let oldCookies = try l.dir(l.temp.appending(path: "slipstream-cookies-\(uuid())"))
        _ = try l.file(oldCookies.appending(path: "cookies.txt")); try l.setAge(oldCookies, 3600)

        // Its process is reported running.
        #expect(LegacyLeftovers.sweep(in: [l.video], temporaryFolder: l.temp, olderThan: Date(),
                                      legacyRunFolder: l.run, legacyAppRunning: true) == nil)
        // Its run lock is held (a copy launched some other way).
        let held = try #require(MediaCleanup.RunLock.acquire(in: l.run, pid: 4444))
        #expect(LegacyLeftovers.legacyAppHoldsRunLock(in: l.run))
        #expect(LegacyLeftovers.sweep(in: [l.video], temporaryFolder: l.temp, olderThan: Date(),
                                      legacyRunFolder: l.run, legacyAppRunning: false) == nil)
        #expect(exists(oldPartial) && exists(oldCookies))
        held.release()

        // A lock file nobody holds (the app crashed) doesn't block the sweep, and is left where it is.
        let stale = l.run.appending(path: "5555.lock")
        FileManager.default.createFile(atPath: stale.path(percentEncoded: false), contents: Data())
        #expect(!LegacyLeftovers.legacyAppHoldsRunLock(in: l.run))
        let removed = try #require(LegacyLeftovers.sweep(in: [l.video], temporaryFolder: l.temp, olderThan: Date(),
                                                         legacyRunFolder: l.run, legacyAppRunning: false))
        #expect(removed.count == 2)
        #expect(!exists(oldPartial) && !exists(oldCookies))
        #expect(exists(stale))
    }

    @Test func ospreysOwnSweepIgnoresTheFormerAppsNames() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let oldPartial = try l.file(l.video.appending(path: "Clip [a].slipstream-partial.mp4"), mark: oldMark)
        let oldHidden = try l.dir(l.video.appending(path: ".slipstream-media-\(uuid())"))
        _ = MediaCleanup.sweepLeftovers(in: [l.video], temporaryFolder: l.temp, olderThan: Date())
        #expect(exists(oldPartial) && exists(oldHidden))
    }
}
