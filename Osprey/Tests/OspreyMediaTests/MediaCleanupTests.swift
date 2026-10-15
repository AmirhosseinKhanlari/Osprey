import Foundation
import Testing
@testable import OspreyMedia

/// Quitting must leave no yt-dlp/ffmpeg process groups or cookie files behind, and the next launch sweeps what a crash left.
@Suite struct MediaCleanupTests {
    // MARK: Registry and terminateAll

    @Test func terminateAllKillsEveryRegisteredGroup() async throws {
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(hang: true, grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile) }
        let child = try ChildProcess.spawn(executable: fake.executable, arguments: [], environment: [:])
        let out = PipeReader(fd: child.stdoutFD), err = PipeReader(fd: child.stderrFD)
        defer { out.stop(); err.stop(); MediaCleanup.shared.unregister(child) }
        #expect(await waitUntil { readPID(pidFile) != nil })
        let grandchild = try #require(readPID(pidFile))

        // A private registry, so this test can't kill other tests' processes.
        let registry = MediaCleanup()
        registry.register(child)
        #expect(registry.isTracking(child))
        registry.terminateAll()                               // synchronous: SIGKILL to the group

        #expect(await child.waitForExit() == 128 + SIGKILL)
        #expect(await waitUntil(timeout: 3) { processIsGone(grandchild) })
        #expect(!registry.isTracking(child))
    }

    @Test func terminateAllDeletesLiveCookieJars() throws {
        let jar = try CookieJarFile.write(cookieHeader: "SID=secret", for: URL(string: "https://www.youtube.com/")!)
        defer { jar.delete() }
        MediaCleanup.shared.unregister(jar)
        let registry = MediaCleanup()
        registry.register(jar)
        registry.terminateAll()
        #expect(!FileManager.default.fileExists(atPath: jar.url.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(!registry.isTracking(jar))
    }

    @Test func aProcessStartedAfterTerminateAllIsKilledAtOnce() async throws {
        let fake = try FakeTool(hang: true)
        defer { fake.cleanUp() }
        let registry = MediaCleanup()
        registry.terminateAll()
        let child = try ChildProcess.spawn(executable: fake.executable, arguments: [], environment: [:])
        let out = PipeReader(fd: child.stdoutFD), err = PipeReader(fd: child.stderrFD)
        defer { out.stop(); err.stop(); MediaCleanup.shared.unregister(child) }
        registry.register(child)
        #expect(await child.waitForExit() == 128 + SIGKILL)
    }

    @Test func spawnedProcessesAreTrackedUntilTheirRunEnds() async throws {
        let fake = try FakeTool(stdoutLines: ["hi"])
        defer { fake.cleanUp() }
        let child = try ChildProcess.spawn(executable: fake.executable, arguments: [], environment: [:])
        #expect(MediaCleanup.shared.isTracking(child))
        let out = PipeReader(fd: child.stdoutFD), err = PipeReader(fd: child.stderrFD)
        _ = await child.waitForExit()
        out.stop(); err.stop()
        MediaCleanup.shared.unregister(child)
        #expect(!MediaCleanup.shared.isTracking(child))

        let before = MediaCleanup.shared.trackedProcessCount
        _ = try await ProcessRunner.run(fake.executable, [], timeout: 10)
        #expect(MediaCleanup.shared.trackedProcessCount <= before)   // ProcessRunner releases what it spawned
    }

    @Test func cookieJarsAreTrackedUntilDeleted() throws {
        let jar = try CookieJarFile.write(cookieHeader: "a=b", for: URL(string: "https://x.test/")!)
        #expect(MediaCleanup.shared.isTracking(jar))
        jar.delete()
        #expect(!MediaCleanup.shared.isTracking(jar))
    }

    // MARK: Launch sweep

    private struct Layout {
        let root = TestTemp.root.appending(path: "osprey-tests-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        var temp: URL { root.appending(path: "tmp", directoryHint: .isDirectory) }
        var video: URL { root.appending(path: "Video", directoryHint: .isDirectory) }
        var music: URL { root.appending(path: "Music", directoryHint: .isDirectory) }
        var elsewhere: URL { root.appending(path: "Elsewhere", directoryHint: .isDirectory) }

        func dir(_ url: URL, age: TimeInterval) throws -> URL {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
            return url
        }

        func file(_ url: URL, age: TimeInterval) throws -> URL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
            return url
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func mark(_ url: URL) throws { try MediaCleanup.markAsPartial(url) }

    /// Fix round 2 (C1): only Osprey's own, marked leftovers go; a user's `Report.partial.pdf` never does.
    @Test func sweepRemovesOnlyMarkedLeftoversOlderThanTheLaunch() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let uuid = { UUID().uuidString }
        let old: TimeInterval = 3600, fresh: TimeInterval = -60      // fresh = modified after the launch cutoff
        func age(_ url: URL, _ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)],
                                                  ofItemAtPath: url.path(percentEncoded: false))
        }

        // Temporary folder: a cookie folder holding only its cookies.txt goes; anything else stays.
        let oldCookies = try l.dir(l.temp.appending(path: "osprey-cookies-\(uuid())"), age: old)
        _ = try l.file(oldCookies.appending(path: "cookies.txt"), age: old)
        try age(oldCookies, old)
        let crowdedCookies = try l.dir(l.temp.appending(path: "osprey-cookies-\(uuid())"), age: old)
        let crowdedNote = try l.file(crowdedCookies.appending(path: "notes.txt"), age: old)
        try age(crowdedCookies, old)
        let newCookies = try l.dir(l.temp.appending(path: "osprey-cookies-\(uuid())"), age: fresh)
        let oddCookies = try l.dir(l.temp.appending(path: "osprey-cookies-mine"), age: old)

        // Our marked partial goes; unmarked look-alikes and other ".partial." files stay.
        let ours = try l.file(l.video.appending(path: "Clip [abc].osprey-partial.mp4"), age: old)
        try mark(ours); try age(ours, old)
        let oursMP3 = try l.file(l.music.appending(path: "Song [x].osprey-partial.mp3"), age: old)
        try mark(oursMP3); try age(oursMP3, old)
        let unmarked = try l.file(l.video.appending(path: "Other [d].osprey-partial.mp4"), age: old)
        let newOurs = try l.file(l.video.appending(path: "New [e].osprey-partial.mkv"), age: fresh)
        try mark(newOurs); try age(newOurs, fresh)
        let userFiles = try [
            l.file(l.video.appending(path: "Report.partial.pdf"), age: old),
            l.file(l.video.appending(path: "Clip.partial.mp4"), age: old),
            l.file(l.music.appending(path: "Thesis.partial.pdf"), age: old),
            l.file(l.video.appending(path: "Clip [abc].mp4"), age: old),
        ]

        // Hidden part folders: only an exact name holding only part files goes, file by file.
        let oldHidden = try l.dir(l.video.appending(path: ".osprey-media-\(uuid())"), age: old)
        for name in ["video.mp4.part", "video.mp4.part-Frag3", "audio.m4a", "audio.m4a.slpart", "audio.m4a.slpart.json", "subtitle.vtt"] {
            _ = try l.file(oldHidden.appending(path: name), age: old)
        }
        try age(oldHidden, old)
        let mixedHidden = try l.dir(l.video.appending(path: ".osprey-media-\(uuid())"), age: old)
        let mixedKeep = try l.file(mixedHidden.appending(path: "keep.txt"), age: old)
        let mixedPart = try l.file(mixedHidden.appending(path: "video.mp4"), age: old)
        try age(mixedHidden, old)
        let nestedHidden = try l.dir(l.video.appending(path: ".osprey-media-\(uuid())"), age: old)
        let nestedFile = try l.file(nestedHidden.appending(path: "video/inner.txt"), age: old)
        try age(nestedHidden, old)
        let newHidden = try l.dir(l.video.appending(path: ".osprey-media-\(uuid())"), age: fresh)
        let oddHidden = try l.dir(l.video.appending(path: ".osprey-media-notes"), age: old)
        // A playlist subfolder is looked in; anything deeper is not.
        let playlistHidden = try l.dir(l.video.appending(path: "My List/.osprey-media-\(uuid())"), age: old)
        let playlistPartial = try l.file(l.video.appending(path: "My List/Song [y].osprey-partial.mp4"), age: old)
        try mark(playlistPartial); try age(playlistPartial, old)
        let deepHidden = try l.dir(l.video.appending(path: "My List/Deeper/.osprey-media-\(uuid())"), age: old)
        // Folders that aren't the media folders are never touched, even with marked items.
        let elsewhereHidden = try l.dir(l.elsewhere.appending(path: ".osprey-media-\(uuid())"), age: old)
        let elsewherePartial = try l.file(l.elsewhere.appending(path: "Clip.osprey-partial.mp4"), age: old)
        try mark(elsewherePartial); try age(elsewherePartial, old)

        let removed = MediaCleanup.sweepLeftovers(in: [l.video, l.music, l.video, l.root.appending(path: "Missing")],
                                                  temporaryFolder: l.temp, olderThan: Date())

        for gone in [oldCookies, ours, oursMP3, oldHidden, playlistHidden, playlistPartial] {
            #expect(!exists(gone), "\(gone.lastPathComponent) should be removed")
        }
        for kept in [crowdedCookies, crowdedNote, newCookies, oddCookies, unmarked, newOurs, mixedHidden, mixedKeep, mixedPart,
                     nestedHidden, nestedFile, newHidden, oddHidden, deepHidden, elsewhereHidden, elsewherePartial] + userFiles {
            #expect(exists(kept), "\(kept.lastPathComponent) should be kept")
        }
        #expect(removed.count == 6)
    }

    @Test func partialsAreMarkedAndRecognised() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let file = try l.file(l.video.appending(path: "x.osprey-partial.mp4"), age: 0)
        #expect(!MediaCleanup.isMarkedPartial(file))
        try MediaCleanup.markAsPartial(file)
        #expect(MediaCleanup.isMarkedPartial(file))
    }

    // MARK: Two running copies (N1)

    @Test func anotherRunningCopySkipsTheSweep() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let run = l.root.appending(path: "run", directoryHint: .isDirectory)
        let mine = try #require(MediaCleanup.RunLock.acquire(in: run, pid: 1111))
        #expect(!MediaCleanup.RunLock.otherCopiesRunning(in: run, excluding: 1111))
        let other = try #require(MediaCleanup.RunLock.acquire(in: run, pid: 2222))
        #expect(MediaCleanup.RunLock.otherCopiesRunning(in: run, excluding: 1111))
        other.release()
        // A lock file nobody holds (a crashed copy) doesn't count, and is removed.
        FileManager.default.createFile(atPath: run.appending(path: "3333.lock").path(percentEncoded: false), contents: Data())
        #expect(!MediaCleanup.RunLock.otherCopiesRunning(in: run, excluding: 1111))
        #expect(!exists(run.appending(path: "3333.lock")))
        mine.release()
        #expect(!exists(run.appending(path: "1111.lock")))
    }

    @Test func sweepFollowsNoSymlinks() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let target = try l.dir(l.elsewhere.appending(path: "Target"), age: 3600)
        let victim = try l.file(target.appending(path: "Keep.osprey-partial.mp4"), age: 3600)
        try MediaCleanup.markAsPartial(victim)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: victim.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: l.video, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: l.video.appending(path: "Linked"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: l.video.appending(path: ".osprey-media-\(UUID().uuidString)"), withDestinationURL: target)
        _ = MediaCleanup.sweepLeftovers(in: [l.video], temporaryFolder: l.temp, olderThan: Date())
        #expect(exists(victim) && exists(target))
    }

    @Test func aReservedNameGetsAMarkedOspreyPartial() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        try FileManager.default.createDirectory(at: l.video, withIntermediateDirectories: true)
        let first = try MediaDownload.reserveName(in: l.video, name: "Clip [a].mp4")
        let placeholder = l.video.appending(path: "Clip [a].osprey-partial.mp4")
        #expect(first.lastPathComponent == "Clip [a].mp4")
        #expect(exists(placeholder) && MediaCleanup.isMarkedPartial(placeholder))
        #expect(try MediaDownload.reserveName(in: l.video, name: "Clip [a].mp4").lastPathComponent == "Clip [a] 2.mp4")
    }

    /// A restored download's hidden folder survives the launch sweep; an unknown one is still deleted.
    @Test func theSweepKeepsTheFoldersOfRestoredDownloads() throws {
        let l = Layout()
        defer { try? FileManager.default.removeItem(at: l.root) }
        let restored = UUID(), restoredInPlaylist = UUID(), unknown = UUID()
        var folders: [URL] = []
        for (parent, id) in [(l.video, restored), (l.video.appending(path: "My List"), restoredInPlaylist), (l.video, unknown)] {
            let hidden = try l.dir(parent.appending(path: ".osprey-media-\(id.uuidString)"), age: 3600)
            _ = try l.file(hidden.appending(path: "video.mp4.part"), age: 3600)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                                  ofItemAtPath: hidden.path(percentEncoded: false))
            folders.append(hidden)
        }
        let removed = MediaCleanup.sweepLeftovers(in: [l.video], temporaryFolder: l.temp, olderThan: Date(),
                                                  keeping: [restored, restoredInPlaylist])
        #expect(exists(folders[0]) && exists(folders[1]))
        #expect(!exists(folders[2]))
        #expect(removed.count == 1)
    }
}
