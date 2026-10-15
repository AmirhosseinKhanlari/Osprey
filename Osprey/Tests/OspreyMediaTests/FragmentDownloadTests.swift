import Foundation
import Testing
import OspreyEngine
@testable import OspreyMedia

private func format() -> MediaFormat {
    let json = #"{"format_id":"hls-720","ext":"mp4","protocol":"m3u8_native"}"#
    return try! JSONDecoder().decode(MediaFormat.self, from: Data(json.utf8))
}

private func tempDestination() throws -> URL {
    let dir = TestTemp.root.appending(path: "frag-dest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "video.mp4")
}

private func makeDownload(_ fake: FakeTool, destination: URL, cookies: String? = nil, limit: Double? = nil, grace: TimeInterval = 5) -> YtDlpFragmentDownload {
    YtDlpFragmentDownload(id: UUID(), pageURL: URL(string: "https://x.test/watch?v=1")!, format: format(), destination: destination,
                          tools: tools(with: fake), cookieHeader: cookies, speedLimit: limit, pauseGrace: grace)
}

private func prog(_ n: Int) -> String { "SLIPPROG \(n * 1000) 10000 NA 5000 3 \(n) 10" }

@Suite struct FragmentDownloadTests {
    @Test func snapshotAdvancesAndCompletes() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stdoutLines: (1...5).map(prog), lineDelay: 0.15, writesDestination: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        var seen = Set<Int64>()
        let done = await waitUntil {
            let s = await job.snapshot()
            if s.downloaded > 0 { seen.insert(s.downloaded) }
            if case .downloading = s.state { #expect(!s.acceptsRanges); #expect(!s.lanes.isEmpty) }
            return s.state == .completed
        }
        #expect(done)
        #expect(seen.count >= 2)            // progress was visible while the process was still running
        let s = await job.snapshot()
        #expect(s.fileName == "video.mp4" && s.destination == dest)
        #expect(FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)))
    }

    @Test func argumentsAreCorrect() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(writesDestination: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest, cookies: "SID=1", limit: 500_000)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        let args = try fake.arguments()
        let i = try #require(args.firstIndex(of: "--concurrent-fragments"))
        #expect(args[i + 1] == "8")
        #expect(args.contains("--newline") && args.contains("--continue"))
        #expect(args[try #require(args.firstIndex(of: "-f")) + 1] == "hls-720")
        #expect(args[try #require(args.firstIndex(of: "--limit-rate")) + 1] == "500000")
        #expect(args[try #require(args.firstIndex(of: "-o")) + 1] == dest.path(percentEncoded: false))
        #expect(args.last == "https://x.test/watch?v=1")
        #expect(!args.contains("--allow-unplayable-formats"))
    }

    @Test func percentSignsInTheDestinationAreEscaped() async throws {
        let dir = TestTemp.root.appending(path: "frag-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: "100% real.mp4")
        let fake = try FakeTool()
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state != .downloading })
        let args = try fake.arguments()
        #expect(args[try #require(args.firstIndex(of: "-o")) + 1] == dir.path(percentEncoded: false) + "/100%% real.mp4")
    }

    @Test func pauseSendsSIGINTThenRestartContinues() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stdoutLines: [prog(2)], writesDestination: true, trapInterrupt: true, hangFirstRunOnly: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded == 2000 })
        await job.pause()
        #expect(await job.snapshot().state == .paused)
        #expect(FileManager.default.fileExists(atPath: fake.sigintMarker.path(percentEncoded: false)))   // SIGINT really arrived
        // A paused task stays paused (the trapped exit code 130 isn't a failure).
        try await Task.sleep(for: .milliseconds(200))
        #expect(await job.snapshot().state == .paused)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        #expect(try fake.arguments().contains("--continue"))
    }

    @Test func pauseKillsTheWholeProcessGroup() async throws {
        let dest = try tempDestination()
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(stdoutLines: [prog(1)], trapInterrupt: true, hang: true, grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded > 0 })
        let pid = try #require(readPID(pidFile))
        #expect(!processIsGone(pid))
        await job.pause()
        #expect(await waitUntil(timeout: 3) { processIsGone(pid) })
    }

    @Test func discardKillsTheGroupAndDeletesPartialFiles() async throws {
        let dest = try tempDestination()
        let dir = dest.deletingLastPathComponent()
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(stdoutLines: [prog(1)], writesDestination: true, hang: true, grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile); try? FileManager.default.removeItem(at: dir) }
        for name in ["video.mp4.part", "video.mp4.part-Frag3", "video.mp4.ytdl", "video.temp.mp4"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        try Data("keep".utf8).write(to: dir.appending(path: "other.mp4"))
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded > 0 })
        let pid = try #require(readPID(pidFile))
        await job.discard()
        #expect(await waitUntil(timeout: 3) { processIsGone(pid) })
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(left == ["other.mp4"])
    }

    @Test func privateVideoFailsAsUnavailable() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stderr: "ERROR: [youtube] abc: Private video", exitCode: 1)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state != .downloading })
        #expect(await job.snapshot().state == .failed(MediaError.unavailable.userMessage))
    }

    @Test func cookieFileIsDeletedAfterTheRun() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(writesDestination: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest, cookies: "SID=secret")
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        let args = try fake.arguments()
        let path = args[try #require(args.firstIndex(of: "--cookies")) + 1]
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    @Test func missingYtDlpFails() async throws {
        let dest = try tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let empty = TestTemp.root.appending(path: "no-tools-\(UUID().uuidString)")
        let job = YtDlpFragmentDownload(id: UUID(), pageURL: URL(string: "https://x.test/v")!, format: format(), destination: dest,
                                        tools: MediaTools(managedFolder: empty, homebrewFolders: []), cookieHeader: nil, speedLimit: nil)
        await job.start()
        #expect(await job.snapshot().state == .failed(MediaError.toolMissing("yt-dlp").userMessage))
    }

    @Test func ffmpegLocationIsPassedWhenFFmpegIsFound() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(writesDestination: true)
        try fake.addFakeFFmpeg()
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        let args = try fake.arguments()
        let i = try #require(args.firstIndex(of: "--ffmpeg-location"))
        #expect(args[i + 1] == fake.folder.appending(path: "ffmpeg").path(percentEncoded: false))
    }

    @Test func noFFmpegLocationWithoutFFmpeg() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(writesDestination: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        #expect(!(try fake.arguments().contains("--ffmpeg-location")))
    }

    @Test func startDuringPauseRelaunches() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stdoutLines: [prog(2)], writesDestination: true, trapInterrupt: true, hangFirstRunOnly: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded == 2000 })
        let pausing = Task { await job.pause() }
        #expect(await waitUntil { await job.snapshot().state == .paused })
        await job.start()                       // the old process may still be exiting
        await pausing.value
        #expect(await waitUntil { await job.snapshot().state == .completed })
    }

    @Test func pauseDoesNotMaskAnEarlierFailure() async throws {
        let dest = try tempDestination()
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        // The leader exits 1 at once, but its grandchild keeps the pipes open, so the exit is processed ~2 s later.
        let fake = try FakeTool(stderr: "ERROR: [youtube] abc: Private video", exitCode: 1, grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        try await Task.sleep(for: .milliseconds(500))
        await job.pause()
        #expect(await waitUntil { await job.snapshot().state != .downloading })
        #expect(await job.snapshot().state == .failed(MediaError.unavailable.userMessage))
    }

    @Test func exitZeroWithoutAFileFails() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool()
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state != .downloading })
        #expect(await job.snapshot().state == .failed(MediaError.extractionFailed("yt-dlp produced no file").userMessage))
    }

    @Test func emptyFileFails() async throws {
        let dest = try tempDestination()
        try Data().write(to: dest)
        let fake = try FakeTool()
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state != .downloading })
        #expect(await job.snapshot().state == .failed(MediaError.extractionFailed("yt-dlp produced no file").userMessage))
    }

    @Test func leaderIgnoringSIGINTIsKilledAfterTheGrace() async throws {
        let dest = try tempDestination()
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(stdoutLines: [prog(1)], hang: true, grandchildPIDFile: pidFile, ignoreInterrupt: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest, grace: 0.6)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded > 0 })
        let pid = try #require(readPID(pidFile))
        let began = Date()
        await job.pause()
        let took = Date().timeIntervalSince(began)
        #expect(took >= 0.5 && took < 4)        // waited out the grace, then SIGKILL
        #expect(await job.snapshot().state == .paused)
        #expect(await waitUntil(timeout: 3) { processIsGone(pid) })
    }

    @Test(arguments: [(1, 3, 3), (3, 10, 8), (9, 10, 2), (10, 10, 1)])
    func lanesFollowTheFragmentCounters(index: Int, count: Int, lanes: Int) async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stdoutLines: ["SLIPPROG 1000 10000 NA 8000 3 \(index) \(count)"], hang: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded > 0 })
        let s = await job.snapshot()
        #expect(s.lanes.count == lanes)
        #expect(abs(s.lanes.reduce(0) { $0 + $1.bytesPerSecond } - 8000) < 1)
        await job.discard()
    }

    @Test func singleLaneWithoutFragmentInfo() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stdoutLines: ["SLIPPROG 1000 NA NA NA NA NA NA"], hang: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded > 0 })
        #expect(await job.snapshot().lanes.count == 1)
        await job.discard()
    }

    @Test func errorsMapFromTheLastERRORLine() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stderr: "ERROR: [x] retrying: Sign in to continue\nERROR: [youtube] abc: Private video", exitCode: 1)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state != .downloading })
        #expect(await job.snapshot().state == .failed(MediaError.unavailable.userMessage))
    }

    @Test(arguments: [Double.nan, .infinity, 0, -5, 0.4])
    func invalidSpeedLimitsAreIgnored(limit: Double) async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(writesDestination: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest, limit: limit)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        #expect(!(try fake.arguments().contains("--limit-rate")))
    }

    @Test func hugeSpeedLimitIsClamped() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(writesDestination: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest, limit: 1e30)
        await job.start()
        #expect(await waitUntil { await job.snapshot().state == .completed })
        let args = try fake.arguments()
        #expect(Int64(args[try #require(args.firstIndex(of: "--limit-rate")) + 1]) != nil)
    }

    @Test func quittingInterruptsYtDlpSoItKeepsItsPartialFiles() async throws {
        let dest = try tempDestination()
        let fake = try FakeTool(stdoutLines: [prog(2)], trapInterrupt: true, hang: true)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let job = makeDownload(fake, destination: dest)
        await job.start()
        #expect(await waitUntil { await job.snapshot().downloaded == 2000 })
        await job.suspendForQuit()
        #expect(await job.snapshot().state == .paused)
        #expect(FileManager.default.fileExists(atPath: fake.sigintMarker.path(percentEncoded: false)))   // SIGINT, not SIGKILL
    }
}
