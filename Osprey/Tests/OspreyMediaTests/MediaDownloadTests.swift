import CoreServices
import Foundation
import Testing
import OspreyEngine
@testable import OspreyMedia

// MARK: Fakes

/// A scripted part: once started it completes (writing its file) after `completeAfter` snapshot calls, or fails after `failAfter`.
private actor FakePart: DownloadTask {
    nonisolated let id = UUID()
    let file: URL
    let total: Int64?
    let segments: [Segment]
    var completeAfter: Int
    var failAfter: Int?
    var failMessage = "boom"
    /// Before going to `.downloading`, start() sleeps this long (to open a race window).
    var startDelay: Duration?
    /// Runs inside snapshot() just before the part fails (lets a test record a resolver error).
    var beforeFailing: (@Sendable () -> Void)?

    private(set) var state: DownloadState = .idle
    private(set) var polls = 0
    private(set) var starts = 0
    private(set) var pauses = 0
    private(set) var discards = 0
    private(set) var limits: [Double?] = []

    init(file: URL, total: Int64?, segments: [Segment], completeAfter: Int, failAfter: Int?) {
        self.file = file
        self.total = total
        self.segments = segments
        self.completeAfter = completeAfter
        self.failAfter = failAfter
    }

    func configure(startDelay: Duration?) { self.startDelay = startDelay }
    /// The part stops on its own (a pause that landed after a newer start, say) while the download still runs.
    func stopOnItsOwn(to stopped: DownloadState = .paused) { if state == .downloading { state = stopped } }
    func configure(beforeFailing: @escaping @Sendable () -> Void) { self.beforeFailing = beforeFailing }

    func start() async {
        starts += 1
        if let startDelay { try? await Task.sleep(for: startDelay) }
        guard state != .completed, state != .downloading else { return }
        state = .downloading
    }

    func pause() async {
        pauses += 1
        if state == .downloading { state = .paused }
    }

    func setSpeedLimit(_ bytesPerSecond: Double?) { limits.append(bytesPerSecond) }

    func snapshot() -> DownloadSnapshot {
        if state == .downloading {
            polls += 1
            if let failAfter, polls >= failAfter {
                beforeFailing?()
                state = .failed(failMessage)
                self.failAfter = nil            // fails once; a restart then keeps downloading
            } else if polls >= completeAfter {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("part".utf8).write(to: file)
                state = .completed
            }
        }
        let downloaded = segments.reduce(0) { $0 + $1.received }
        let running = state == .downloading
        return DownloadSnapshot(state: state, fileName: file.lastPathComponent, totalSize: total, downloaded: downloaded,
                                bytesPerSecond: running ? 100 : 0, segments: segments,
                                lanes: running ? [LaneSnapshot(id: 0, segmentID: segments.first?.id, phase: .receiving, bytesPerSecond: 100)] : [],
                                acceptsRanges: true, etag: nil, destination: state == .completed ? file : nil)
    }

    func discard() async {
        discards += 1
        state = .idle
        try? FileManager.default.removeItem(at: file)
    }
}

private struct PartScript: Sendable {
    var total: Int64? = 1000
    var segments: [Segment] = [Segment(id: 0, start: 0, end: 999, received: 0)]
    var completeAfter = 2
    var failAfter: Int?
}

/// Builds `FakePart`s from scripts, in part order, and remembers them and their contexts.
private final class FakeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [PartScript]
    private var made: [FakePart] = []
    private var contexts: [PartFactory.Context] = []

    init(_ scripts: [PartScript]) { self.scripts = scripts }

    var parts: [FakePart] { lock.withLock { made } }
    var seen: [PartFactory.Context] { lock.withLock { contexts } }

    var factory: PartFactory {
        PartFactory { [self] context in
            lock.withLock {
                let script = scripts.isEmpty ? PartScript() : scripts.removeFirst()
                let part = FakePart(file: context.file, total: script.total, segments: script.segments,
                                    completeAfter: script.completeAfter, failAfter: script.failAfter)
                made.append(part)
                contexts.append(context)
                return part
            }
        }
    }
}

private final class FakeMerger: MediaMerging, @unchecked Sendable {
    struct MuxCall: Equatable { var video: URL, audio: URL, subtitle: URL?, container: Container, output: URL }
    private let lock = NSLock()
    private var _muxCalls: [MuxCall] = []
    private var _mp3Calls: [(URL, URL)] = []
    private var failuresLeft: Int
    private let delay: Duration?
    private var _subtitleText: String?

    /// Every mux that embeds a subtitle fails (as ffmpeg does on a subtitle it can't convert).
    private let failsWithSubtitle: Bool

    init(failures: Int = 0, delay: Duration? = nil, failsWithSubtitle: Bool = false) {
        failuresLeft = failures
        self.delay = delay
        self.failsWithSubtitle = failsWithSubtitle
    }

    var muxCalls: [MuxCall] { lock.withLock { _muxCalls } }
    var mp3Calls: [(URL, URL)] { lock.withLock { _mp3Calls } }
    var subtitleText: String? { lock.withLock { _subtitleText } }
    private var _subtitleLanguage: String?
    var subtitleLanguage: String? { lock.withLock { _subtitleLanguage } }

    func mux(video: URL, audio: URL, subtitle: URL?, subtitleLanguage: String?, container: Container, to output: URL) async throws {
        if let delay { try await Task.sleep(for: delay) }
        let text = subtitle.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let fail = lock.withLock { () -> Bool in
            _muxCalls.append(MuxCall(video: video, audio: audio, subtitle: subtitle, container: container, output: output))
            _subtitleText = text
            _subtitleLanguage = subtitleLanguage
            if failsWithSubtitle && subtitle != nil { return true }
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
        if fail { throw MediaError.muxFailed("bad input") }
        #expect(FileManager.default.fileExists(atPath: video.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: audio.path(percentEncoded: false)))
        try Data("merged".utf8).write(to: output)
    }

    func convertToMP3(_ input: URL, to output: URL) async throws {
        lock.withLock { _mp3Calls.append((input, output)) }
        try Data("mp3".utf8).write(to: output)
    }
}

// MARK: Helpers

private func format(_ id: String, ext: String, url: String? = nil, headers: [String: String] = [:], proto: String = "https") -> MediaFormat {
    var object: [String: Any] = ["format_id": id, "ext": ext, "protocol": proto, "http_headers": headers]
    if let url { object["url"] = url }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(MediaFormat.self, from: data)
}

private func info(title: String = "My: Video/Clip", id: String = "abc123") -> MediaInfo {
    let json = #"{"id":"\#(id)","title":"\#(title)","formats":[]}"#
    return try! JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
}

private let videoPart = MediaPart(format: format("136", ext: "mp4", url: "https://media.example/136"), role: .video)
private let audioPart = MediaPart(format: format("140", ext: "m4a", url: "https://media.example/140"), role: .audio)
private let twoPartPlan = MediaPlan(parts: [videoPart, audioPart], container: .mp4, convertToMP3: false, subtitle: nil, subtitleLanguage: nil)

private func tempFolder() throws -> URL {
    let dir = TestTemp.root.appending(path: "media-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

private func noTools() -> MediaTools {
    MediaTools(managedFolder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), homebrewFolders: [])
}

private func makeDownload(plan: MediaPlan = twoPartPlan, folder: URL, factory: FakeFactory, merger: FakeMerger,
                          speedLimit: Double? = nil, info: MediaInfo = info()) -> MediaDownload {
    let tools = noTools()
    return MediaDownload(pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!, info: info, plan: plan, folder: folder,
                         cookieHeader: nil, speedLimit: speedLimit, isPrivate: false, tools: tools,
                         extractor: MediaExtractor(tools: tools), partFactory: factory.factory, merger: merger,
                         pollInterval: .milliseconds(20))
}

private func hiddenFolder(_ download: MediaDownload, in folder: URL) -> URL {
    folder.appending(path: ".osprey-media-\(download.id.uuidString)")
}

// MARK: Tests

@Suite struct MediaDownloadTests {
    @Test func twoPartsAreMuxedIntoTheFinalFileAndTheHiddenFolderIsRemoved() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(), PartScript(completeAfter: 3)])
        let merger = FakeMerger()
        let download = makeDownload(folder: folder, factory: factory, merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })

        let hidden = hiddenFolder(download, in: folder)
        let contexts = factory.seen
        #expect(contexts.map(\.part.role) == [.video, .audio])
        #expect(contexts.map(\.file.lastPathComponent) == ["video.mp4", "audio.m4a"])
        #expect(contexts.allSatisfy { $0.file.deletingLastPathComponent().path(percentEncoded: false).hasPrefix(hidden.path(percentEncoded: false)) })

        let final = folder.appending(path: "My- Video-Clip [abc123].mp4")
        let call = try #require(merger.muxCalls.first)
        #expect(merger.muxCalls.count == 1)
        #expect(call.video.lastPathComponent == "video.mp4" && call.audio.lastPathComponent == "audio.m4a")
        #expect(call.subtitle == nil && call.container == .mp4)
        #expect(call.output.standardizedFileURL == final.standardizedFileURL)
        #expect(exists(final))
        #expect(!exists(hidden))

        let media = await download.mediaSnapshot()
        #expect(media.finalFile?.standardizedFileURL == final.standardizedFileURL)
        #expect(media.parts.map(\.role) == [.video, .audio])
        #expect(media.parts.allSatisfy { $0.state == .completed })
        let snap = await download.snapshot()
        #expect(snap.state == .completed)
        #expect(snap.destination?.standardizedFileURL == final.standardizedFileURL)
    }

    @Test func hugePartSizesDoNotOverflowTheSnapshot() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let big = Int64.max - 10
        let script = PartScript(total: big, segments: [Segment(id: 0, start: 0, end: big - 1, received: big - 1)], completeAfter: .max)
        let download = makeDownload(folder: folder, factory: FakeFactory([script, script]), merger: FakeMerger())
        await download.start()
        #expect(await waitUntil { await download.snapshot().downloaded > 0 })
        let snap = await download.snapshot()
        #expect(snap.totalSize == nil)                      // the sum doesn't fit: unknown, not a trap
        #expect(snap.downloaded == Int64.max)               // saturated
        #expect(snap.segments.count == 2)
        await download.discard()
    }

    @Test func finalNameIsMadeUnique() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appending(path: "My- Video-Clip [abc123].mp4"))
        let merger = FakeMerger()
        let download = makeDownload(folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(await download.mediaSnapshot().finalFile?.lastPathComponent == "My- Video-Clip [abc123] 2.mp4")
    }

    /// Two downloads of the same video into the same folder, merging at the same time, get different final names.
    @Test func concurrentMergesOfTheSameVideoDoNotShareAName() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let merger = FakeMerger(delay: .milliseconds(300))
        let first = makeDownload(folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        let second = makeDownload(folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        async let a: Void = first.start()
        async let b: Void = second.start()
        _ = await (a, b)
        #expect(await waitUntil {
            let one = await first.mediaSnapshot().phase, two = await second.mediaSnapshot().phase
            return one == .completed && two == .completed
        })
        let firstName = await first.mediaSnapshot().finalFile?.lastPathComponent
        let secondName = await second.mediaSnapshot().finalFile?.lastPathComponent
        let names = Set([firstName, secondName])
        #expect(names == ["My- Video-Clip [abc123].mp4", "My- Video-Clip [abc123] 2.mp4"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).filter { $0.contains(".osprey-partial.") }
        #expect(leftovers.isEmpty)
    }

    /// Ledger 25: while the download runs, a part found paused or idle is started again.
    @Test(arguments: [DownloadState.paused, .idle])
    func aPartThatStoppedOnItsOwnIsRestarted(_ stopped: DownloadState) async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        await download.start()
        let video = factory.parts[0]
        #expect(await video.starts == 1)
        await video.stopOnItsOwn(to: stopped)
        #expect(await waitUntil { await video.starts == 2 })
        #expect(await waitUntil { await video.state == .downloading })
        #expect(await download.mediaSnapshot().phase == .downloading)
        #expect(await factory.parts[1].starts == 1)          // the running part is left alone
        await download.discard()
    }

    @Test func aPausedDownloadDoesNotRestartItsParts() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        await download.start()
        await download.pause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await factory.parts[0].starts == 1)
        #expect(await factory.parts[1].starts == 1)
        await download.discard()
    }

    @Test func combinedSnapshotSumsPartsAndOffsetsSegments() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = PartScript(total: 1000, segments: [Segment(id: 0, start: 0, end: 499, received: 100),
                                                       Segment(id: 1, start: 500, end: 999, received: 50)], completeAfter: .max)
        let audio = PartScript(total: 400, segments: [Segment(id: 0, start: 0, end: 399, received: 10)], completeAfter: .max)
        let download = makeDownload(folder: folder, factory: FakeFactory([video, audio]), merger: FakeMerger())
        #expect(await download.snapshot().fileName == "My- Video-Clip.mp4")
        await download.start()
        #expect(await waitUntil { await download.snapshot().downloaded == 160 })
        let snap = await download.snapshot()
        #expect(snap.state == .downloading)
        #expect(snap.totalSize == 1400)
        #expect(snap.bytesPerSecond == 200)
        #expect(snap.fileName == "My- Video-Clip.mp4")
        #expect(snap.segments.map(\.start) == [0, 500, 1000])
        #expect(snap.segments.map(\.end) == [499, 999, 1399])
        #expect(snap.segments.map(\.received) == [100, 50, 10])
        #expect(Set(snap.segments.map(\.id)).count == 3)
        #expect(snap.lanes.count == 2)
        #expect(Set(snap.lanes.map(\.id)).count == 2)
        // Each lane still points at its own (re-numbered) segment.
        #expect(snap.segments.first { $0.id == snap.lanes[1].segmentID }?.start == 1000)
        let media = await download.mediaSnapshot()
        #expect(media.phase == .downloading)
        #expect(media.parts.map(\.downloaded) == [150, 10])
        #expect(media.parts.map(\.total) == [1000, 400])
        // Each part carries its own, un-offset segments for its share of the bar.
        #expect(media.parts[0].detail?.segments.map(\.start) == [0, 500])
        #expect(media.parts[1].detail?.segments.first?.start == 0)
        #expect(download.folder.standardizedFileURL == folder.standardizedFileURL)
        await download.discard()
    }

    @Test func unknownPartSizeLeavesTotalUnknownAndSegmentsUnshifted() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = PartScript(total: nil, segments: [], completeAfter: .max)
        let audio = PartScript(total: 400, segments: [Segment(id: 0, start: 0, end: 399, received: 10)], completeAfter: .max)
        let download = makeDownload(folder: folder, factory: FakeFactory([video, audio]), merger: FakeMerger())
        await download.start()
        #expect(await waitUntil { await download.snapshot().downloaded == 10 })
        let snap = await download.snapshot()
        #expect(snap.totalSize == nil)
        #expect(snap.segments.map(\.start) == [0])
        await download.discard()
    }

    @Test func aFailingPartFailsTheDownloadAndPausesTheOther() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max, failAfter: 3)])
        let merger = FakeMerger()
        let download = makeDownload(folder: folder, factory: factory, merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .failed(.downloadFailed("boom")) })
        #expect(await waitUntil { await factory.parts[0].state == .paused })
        #expect(await download.snapshot().state == .failed("boom"))
        #expect(merger.muxCalls.isEmpty)
        await download.discard()
    }

    @Test func aResolverErrorIsReportedInsteadOfTheHTTPFailure() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max, failAfter: 2), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        let log = try #require(factory.seen.first?.resolverErrors)
        await factory.parts[0].configure(beforeFailing: { log.record(.formatsChanged) })
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .failed(.formatsChanged) })
        #expect(await download.snapshot().state == .failed(MediaError.formatsChanged.userMessage))
        await download.discard()
    }

    @Test func restartAfterAPartFailureRestartsTheUnfinishedParts() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: 2), PartScript(completeAfter: .max, failAfter: 4)])
        let merger = FakeMerger()
        let download = makeDownload(folder: folder, factory: factory, merger: merger)
        await download.start()
        #expect(await waitUntil { if case .failed = await download.mediaSnapshot().phase { true } else { false } })
        await download.start()
        #expect(await download.mediaSnapshot().phase == .downloading)
        #expect(await factory.parts[0].starts == 1)       // already complete
        #expect(await factory.parts[1].starts == 2)
        await download.discard()
    }

    @Test func pausePausesEveryPart() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        await download.start()
        #expect(await waitUntil { await download.snapshot().lanes.count == 2 })
        await download.pause()
        for part in factory.parts { #expect(await part.state == .paused) }
        #expect(await download.mediaSnapshot().phase == .paused)
        #expect(await download.snapshot().state == .paused)
        await download.start()
        #expect(await download.mediaSnapshot().phase == .downloading)
        for part in factory.parts { #expect(await part.state == .downloading) }
        await download.discard()
    }

    @Test func anMP3PlanIsConverted() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let plan = MediaPlan(parts: [audioPart], container: .mp3, convertToMP3: true, subtitle: nil, subtitleLanguage: nil)
        let merger = FakeMerger()
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript()]), merger: merger)
        #expect(await download.snapshot().fileName == "My- Video-Clip.mp3")
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        let call = try #require(merger.mp3Calls.first)
        #expect(call.0.lastPathComponent == "audio.m4a")
        #expect(call.1.lastPathComponent == "My- Video-Clip [abc123].mp3")
        #expect(merger.muxCalls.isEmpty)
        #expect(exists(folder.appending(path: "My- Video-Clip [abc123].mp3")))
        #expect(!exists(hiddenFolder(download, in: folder)))
    }

    @Test func aSingleCombinedPartIsMovedWithoutFFmpeg() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let combined = MediaPart(format: format("18", ext: "mp4", url: "https://media.example/18"), role: .combined)
        let plan = MediaPlan(parts: [combined], container: .mp4, convertToMP3: false, subtitle: nil, subtitleLanguage: nil)
        let merger = FakeMerger()
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        let final = folder.appending(path: "My- Video-Clip [abc123].mp4")
        #expect(try Data(contentsOf: final) == Data("part".utf8))
        #expect(merger.muxCalls.isEmpty && merger.mp3Calls.isEmpty)
        #expect(!exists(hiddenFolder(download, in: folder)))
    }

    @Test func aMergeFailureKeepsThePartsAndRestartRetriesOnlyTheMerge() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(), PartScript()])
        let merger = FakeMerger(failures: 1)
        let download = makeDownload(folder: folder, factory: factory, merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .failed(.muxFailed("bad input")) })
        #expect(await download.snapshot().state == .failed(MediaError.muxFailed("bad input").userMessage))
        let hidden = hiddenFolder(download, in: folder)
        #expect(exists(hidden.appending(path: "video.mp4")) && exists(hidden.appending(path: "audio.m4a")))

        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(merger.muxCalls.count == 2)
        for part in factory.parts { #expect(await part.starts == 1) }
        #expect(!exists(hidden))
    }

    @Test func pauseDuringTheMergeIsIgnored() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let merger = FakeMerger(delay: .milliseconds(300))
        let download = makeDownload(folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .merging })
        #expect(await download.snapshot().state == .finishing)
        await download.pause()
        #expect(await download.mediaSnapshot().phase == .merging)
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
    }

    @Test func discardDuringTheMergeLeavesNoFinalFile() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let merger = FakeMerger(delay: .milliseconds(300))
        let download = makeDownload(folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .merging })
        await download.discard()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!exists(folder.appending(path: "My- Video-Clip [abc123].mp4")))
        #expect(!exists(hiddenFolder(download, in: folder)))
        #expect(await download.mediaSnapshot().phase == .idle)
        #expect(await download.mediaSnapshot().finalFile == nil)
    }

    @Test func theSpeedLimitIsSplitAcrossRunningParts() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: 2), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger(), speedLimit: 1000)
        #expect(factory.seen.map(\.speedLimit) == [500, 500])
        await download.start()
        #expect(await factory.parts[0].limits.first == 500)
        #expect(await factory.parts[1].limits.first == 500)
        // The video part finishes: the audio part gets the whole limit.
        #expect(await waitUntil { await factory.parts[1].limits.last == 1000 })
        await download.setSpeedLimit(3000)
        #expect(await waitUntil { await factory.parts[1].limits.last == 3000 })
        await download.setSpeedLimit(nil)
        #expect(await waitUntil { await factory.parts[1].limits.last == .some(nil) })
        await download.discard()
    }

    @Test func discardDiscardsThePartsAndDeletesTheHiddenFolder() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: 2), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        await download.start()
        let hidden = hiddenFolder(download, in: folder)
        #expect(await waitUntil { await factory.parts[0].state == .completed })
        #expect(exists(hidden))
        await download.discard()
        for part in factory.parts { #expect(await part.discards == 1) }
        #expect(!exists(hidden))
        // A discarded download never starts again.
        await download.start()
        for part in factory.parts { #expect(await part.state != .downloading) }
        #expect(!exists(hidden))
    }

    @Test func discardDuringAStartDoesNotRelaunchTheParts() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        // The parts only report "downloading" after the discard has run (like a resume that lands late).
        for part in factory.parts { await part.configure(startDelay: .milliseconds(200)) }
        async let starting: Void = download.start()
        try await Task.sleep(for: .milliseconds(50))
        await download.discard()
        await starting
        try await Task.sleep(for: .milliseconds(100))
        for part in factory.parts { #expect(await part.state != .downloading) }
        #expect(!exists(hiddenFolder(download, in: folder)))
        #expect(await download.mediaSnapshot().phase != .downloading)
    }

    @Test func pauseDuringAStartLeavesThePartsPaused() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max)])
        let download = makeDownload(folder: folder, factory: factory, merger: FakeMerger())
        for part in factory.parts { await part.configure(startDelay: .milliseconds(200)) }
        async let starting: Void = download.start()
        try await Task.sleep(for: .milliseconds(50))
        await download.pause()
        await starting
        for part in factory.parts { #expect(await part.state != .downloading) }
        #expect(await download.mediaSnapshot().phase == .paused)
        await download.discard()
    }

    @Test func aSubtitleIsDownloadedAndPassedToTheMuxer() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let server = try MiniHTTPServer(bodies: ["/subs.vtt": Data("WEBVTT\n".utf8)])
        try await server.start()
        defer { server.stop() }
        let track = SubtitleTrack(ext: "vtt", url: server.url(path: "/subs.vtt"), name: "English")
        var plan = twoPartPlan
        plan.subtitle = track
        plan.subtitleLanguage = "en"
        let merger = FakeMerger()
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        let call = try #require(merger.muxCalls.first)
        #expect(call.subtitle?.pathExtension == "vtt")
        #expect(merger.subtitleText == "WEBVTT\n")
    }

    /// YouTube's direct auto-translated captions answer 429; the HLS WebVTT playlist of the same captions is then
    /// fetched segment by segment and joined.
    @Test func aFailedSubtitleFallsBackToTheHLSTrack() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let server = try MiniHTTPServer(bodies: [
            "/fr/index.m3u8": Data("#EXTM3U\n#EXTINF:600,\n/fr/seg1.vtt\n#EXTINF:600,\n/fr/seg2.vtt\n#EXT-X-ENDLIST\n".utf8),
            "/fr/seg1.vtt": Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nUn\n".utf8),
            "/fr/seg2.vtt": Data("WEBVTT\n\n00:10:01.000 --> 00:10:02.000\nDeux\n".utf8),
        ])
        try await server.start()
        defer { server.stop() }
        var plan = twoPartPlan
        plan.subtitle = SubtitleTrack(ext: "srt", url: server.url(path: "/missing.srt"), name: "French")
        plan.subtitleAlternates = [SubtitleTrack(ext: "vtt", url: server.url(path: "/fr/index.m3u8"), name: "French",
                                                 streamProtocol: "m3u8_native")]
        plan.subtitleLanguage = "fr"
        let merger = FakeMerger()
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        let call = try #require(merger.muxCalls.first)
        #expect(call.subtitle?.pathExtension == "vtt")
        #expect(merger.subtitleText == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nUn\n\n00:10:01.000 --> 00:10:02.000\nDeux\n")
        #expect(merger.subtitleLanguage == "fr")
    }

    /// A subtitle problem never costs the download: when every track is refused (here 429, as YouTube does), the
    /// video and audio are merged alone and the item finishes with a warning naming the cause.
    @Test func refusedSubtitlesStillSaveTheVideoWithAWarning() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let server = try MiniHTTPServer(bodies: [:], statuses: ["/fr.srt": "429 Too Many Requests",
                                                                "/fr/index.m3u8": "429 Too Many Requests"])
        try await server.start()
        defer { server.stop() }
        var plan = twoPartPlan
        plan.subtitle = SubtitleTrack(ext: "srt", url: server.url(path: "/fr.srt"), name: "French")
        plan.subtitleAlternates = [SubtitleTrack(ext: "vtt", url: server.url(path: "/fr/index.m3u8"), name: "French",
                                                 streamProtocol: "m3u8_native")]
        plan.subtitleLanguage = "fr"
        let merger = FakeMerger()
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(server.requestedPaths.contains("/fr/index.m3u8"))           // the HLS fallback was tried first
        let snapshot = await download.mediaSnapshot()
        let output = try #require(snapshot.finalFile)
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        #expect(merger.muxCalls.count == 1)
        #expect(merger.muxCalls.first?.subtitle == nil)
        #expect(merger.subtitleLanguage == nil)
        #expect(snapshot.warning == .subtitlesSkipped(.refused(site: "YouTube", status: 429)))
        #expect(snapshot.warning?.userMessage == "Saved without subtitles (YouTube refused the captions)")
        #expect(await download.snapshot().state == .completed)
    }

    /// ffmpeg failing on the subtitle: the merge is redone without it, never reported as a failed merge.
    @Test func aSubtitleThatCantBeEmbeddedStillSavesTheVideoWithAWarning() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let server = try MiniHTTPServer(bodies: ["/fr.vtt": Data("WEBVTT\n".utf8)])
        try await server.start()
        defer { server.stop() }
        var plan = twoPartPlan
        plan.subtitle = SubtitleTrack(ext: "vtt", url: server.url(path: "/fr.vtt"), name: "French")
        plan.subtitleLanguage = "fr"
        let merger = FakeMerger(failsWithSubtitle: true)
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        let snapshot = await download.mediaSnapshot()
        let output = try #require(snapshot.finalFile)
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        #expect(merger.muxCalls.map { $0.subtitle != nil } == [true, false])
        #expect(snapshot.warning == .subtitlesSkipped(.notEmbedded))
        #expect(snapshot.warning?.userMessage == "Saved without subtitles (the captions couldn't be embedded)")
        #expect(snapshot.warning?.userMessage.contains("merge") == false)
        // No leftover reservation placeholders next to the output.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(!names.contains { $0.contains("osprey-partial") })
    }

    @Test func subtitleWarningMessagesNameTheCause() {
        #expect(MediaWarning.subtitlesSkipped(.refused(site: "Vimeo", status: 403)).userMessage
                == "Saved without subtitles (Vimeo refused the captions)")
        #expect(MediaWarning.subtitlesSkipped(.unreachable).userMessage
                == "Saved without subtitles (the captions couldn't be downloaded)")
        #expect(MediaWarning.subtitlesSkipped(.unreadable).userMessage
                == "Saved without subtitles (the captions couldn't be read)")
        #expect(MediaWarning.siteName(for: URL(string: "https://m.youtube.com/watch?v=x")!) == "YouTube")
        #expect(MediaWarning.siteName(for: URL(string: "https://youtu.be/x")!) == "YouTube")
        #expect(MediaWarning.siteName(for: URL(string: "https://www.dailymotion.com/video/x")!) == "dailymotion.com")
    }

    /// M5: a subtitle is fetched only over http(s); a local file is never read into the merge.
    @Test func aNonHTTPSubtitleIsRefused() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appending(path: "secret.vtt")
        try Data("WEBVTT\nsecret\n".utf8).write(to: secret)
        var plan = twoPartPlan
        plan.subtitle = SubtitleTrack(ext: "vtt", url: secret, name: "English")
        plan.subtitleLanguage = "en"
        let merger = FakeMerger()
        let download = makeDownload(plan: plan, folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        // The local file is never read; the video is saved without subtitles, with a warning.
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(merger.muxCalls.map(\.subtitle) == [nil])
        #expect(merger.subtitleText == nil)
        #expect(await download.mediaSnapshot().warning == .subtitlesSkipped(.unreachable))
    }

    // MARK: Live direct parts: URL resolver

    private func fixture(replacing old: String, with new: String) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "youtube_like", withExtension: "json", subdirectory: "Fixtures"))
        let text = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: old, with: new)
        let file = TestTemp.root.appending(path: "fixture-\(UUID().uuidString).json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func theResolverReturnsTheSameFormatsFreshURLAndHeaders() async throws {
        let json = try fixture(replacing: "https://media.example/136", with: "https://media.example/136-fresh")
        let fake = try FakeTool(stdoutFile: json)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: json) }
        let log = ResolverErrorLog()
        let resolver = PartFactory.urlResolver(pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!, formatID: "136",
                                               cookieHeader: "SID=1", extractor: MediaExtractor(tools: tools(with: fake)), errors: log)
        let request = try await resolver()
        #expect(request.url == URL(string: "https://media.example/136-fresh"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UA")
        #expect(try fake.arguments().contains("--cookies"))
        #expect(log.last == nil)
    }

    @Test func theResolverThrowsFormatsChangedWhenTheFormatIsGone() async throws {
        let json = try fixture(replacing: #""format_id":"136""#, with: #""format_id":"999""#)
        let fake = try FakeTool(stdoutFile: json)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: json) }
        #expect(!(try String(contentsOf: json, encoding: .utf8)).contains(#""format_id":"136""#))
        let log = ResolverErrorLog()
        let resolver = PartFactory.urlResolver(pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!, formatID: "136",
                                               cookieHeader: nil, extractor: MediaExtractor(tools: tools(with: fake)), errors: log)
        await #expect(throws: MediaError.formatsChanged) { _ = try await resolver() }
        #expect(log.last == .formatsChanged)
    }

    @Test func liveFactoryBuildsADownloadJobForDirectPartsAndYtDlpForFragmented() throws {
        let tools = noTools()
        func context(_ part: MediaPart) -> PartFactory.Context {
            PartFactory.Context(partID: UUID(), pageURL: URL(string: "https://x.test/v")!, part: part,
                                file: URL(fileURLWithPath: "/tmp/x/video.mp4"), cookieHeader: nil, speedLimit: nil, isPrivate: true,
                                tools: tools, extractor: MediaExtractor(tools: tools), resolverErrors: ResolverErrorLog())
        }
        #expect(PartFactory.live.make(context(videoPart)) is DownloadJob)
        let hls = MediaPart(format: format("hls-720", ext: "mp4", proto: "m3u8_native"), role: .video)
        #expect(PartFactory.live.make(context(hls)) is YtDlpFragmentDownload)
    }
}

// MARK: Real ffmpeg, real HTTP

private let realFFmpeg = "/opt/homebrew/bin/ffmpeg"
private let realFFprobe = "/opt/homebrew/bin/ffprobe"

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realFFmpeg) && FileManager.default.isExecutableFile(atPath: realFFprobe)))
struct MediaDownloadIntegrationTests {
    private func run(_ tool: String, _ args: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(URL(fileURLWithPath: tool), args, timeout: 60)
    }

    @Test func twoDirectPartsAreDownloadedMuxedAndQuarantined() async throws {
        let work = try tempFolder()
        let downloads = try tempFolder()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: downloads) }

        let videoSource = work.appending(path: "v.mp4"), audioSource = work.appending(path: "a.m4a")
        let quiet = ["-y", "-hide_banner", "-loglevel", "error"]
        var r = try await run(realFFmpeg, quiet + ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-c:v", "libx264", "-t", "1",
                                                   videoSource.path(percentEncoded: false)])
        #expect(r.status == 0, "\(r.stderr)")
        r = try await run(realFFmpeg, quiet + ["-f", "lavfi", "-i", "sine=frequency=440", "-c:a", "aac", "-t", "1",
                                               audioSource.path(percentEncoded: false)])
        #expect(r.status == 0, "\(r.stderr)")

        let server = try MiniHTTPServer(bodies: ["/v.mp4": try Data(contentsOf: videoSource), "/a.m4a": try Data(contentsOf: audioSource)])
        try await server.start()
        defer { server.stop() }

        let plan = MediaPlan(parts: [MediaPart(format: format("136", ext: "mp4", url: server.url(path: "/v.mp4").absoluteString,
                                                              headers: ["User-Agent": "UA"]), role: .video),
                                     MediaPart(format: format("140", ext: "m4a", url: server.url(path: "/a.m4a").absoluteString,
                                                              headers: ["User-Agent": "UA"]), role: .audio)],
                             container: .mp4, convertToMP3: false, subtitle: nil, subtitleLanguage: nil)
        let tools = MediaTools(managedFolder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        let download = MediaDownload(pageURL: URL(string: "https://www.example.com/watch?v=abc123")!, info: info(title: "Clip", id: "abc123"),
                                     plan: plan, folder: downloads, cookieHeader: nil, speedLimit: nil, isPrivate: false, tools: tools,
                                     extractor: MediaExtractor(tools: tools))
        await download.start()
        #expect(await waitUntil(timeout: 30) {
            switch await download.mediaSnapshot().phase {
            case .completed, .failed: true
            default: false
            }
        })
        let media = await download.mediaSnapshot()
        #expect(media.phase == .completed)
        let final = try #require(media.finalFile)
        #expect(final.lastPathComponent == "Clip [abc123].mp4")
        #expect(final.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)

        let probe = try await run(realFFprobe, ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0",
                                                final.path(percentEncoded: false)])
        let types = Set(String(decoding: probe.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
        #expect(types == ["video", "audio"])

        let properties = try #require(try final.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Osprey")
        #expect(!exists(hiddenFolder(download, in: downloads)))
        #expect(Set(server.requestedPaths).isSuperset(of: ["/v.mp4", "/a.m4a"]))
    }
}

// MARK: Resuming after a relaunch

private func makeResumed(_ record: MediaRecord, id: UUID, factory: FakeFactory, merger: FakeMerger) -> MediaDownload {
    let tools = noTools()
    return MediaDownload(resuming: record, id: id, pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!,
                         cookieHeader: "SID=1", speedLimit: nil, tools: tools, extractor: MediaExtractor(tools: tools),
                         partFactory: factory.factory, merger: merger, pollInterval: .milliseconds(20))
}

private func savedRecord(folder: URL, id: UUID, phase: MediaRecord.Phase) -> MediaRecord {
    MediaRecord(video: MediaRecord.Video(info()), plan: twoPartPlan, folder: folder, hiddenFolderID: id, phase: phase, warning: nil)
}

/// The audio part's sidecar: 400 of 1 000 bytes on disk.
private func savedAudioState(in hidden: URL) throws -> ResumeState {
    var map = SegmentMap(totalSize: 1_000)
    map.record(400, for: 0)
    let state = ResumeState(url: URL(string: "https://media.example/140")!, destination: hidden.appending(path: "audio.m4a"),
                            headers: [:], totalSize: 1_000, etag: nil, lastModified: nil, acceptsRanges: true, map: map)
    FileManager.default.createFile(atPath: state.partURL.path(percentEncoded: false), contents: Data(count: 1_000))
    try ResumeStore.save(state)
    return state
}

@Suite struct MediaDownloadResumeTests {
    @Test func aResumedDownloadReusesItsFolderAndSkipsFinishedParts() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let hidden = folder.appending(path: ".osprey-media-\(id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: hidden.appending(path: "video.mp4"))          // finished
        try Data("aud".utf8).write(to: hidden.appending(path: "audio.m4a.part"))      // yt-dlp's partial data
        let factory = FakeFactory([PartScript()])
        let merger = FakeMerger()
        let download = makeResumed(savedRecord(folder: folder, id: id, phase: .downloading), id: id, factory: factory, merger: merger)
        #expect(download.id == id && download.hiddenFolderID == id)
        let before = await download.mediaSnapshot()
        #expect(before.phase == .paused)
        #expect(before.parts.map(\.state) == [.completed, .paused])
        #expect(before.parts[1].downloaded == 3)
        #expect(await download.snapshot().state == .paused)

        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(factory.seen.map(\.part.role) == [.audio])                 // only the unfinished part was rebuilt
        #expect(factory.seen.first?.file.deletingLastPathComponent().standardizedFileURL == hidden.standardizedFileURL)
        #expect(factory.seen.first?.cookieHeader == "SID=1")
        let call = try #require(merger.muxCalls.first)
        #expect(call.video.standardizedFileURL == hidden.appending(path: "video.mp4").standardizedFileURL)
        #expect(!exists(hidden))
    }

    @Test func aRestoredFailureShowsItsMessageThenResumes() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let hidden = folder.appending(path: ".osprey-media-\(id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: hidden.appending(path: "video.mp4"))          // finished before the failure
        let factory = FakeFactory([PartScript()])
        let merger = FakeMerger()
        let tools = noTools()
        let download = MediaDownload(resuming: savedRecord(folder: folder, id: id, phase: .downloading), id: id,
                                     pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!, cookieHeader: nil,
                                     speedLimit: nil, tools: tools, extractor: MediaExtractor(tools: tools),
                                     partFactory: factory.factory, merger: merger, pollInterval: .milliseconds(20),
                                     failure: "The network connection was lost.")
        #expect(await download.snapshot().state == .failed("The network connection was lost."))
        #expect(await download.mediaSnapshot().parts.map(\.state).first == .completed)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(factory.seen.map(\.part.role) == [.audio])                 // only what was missing is fetched
        #expect(merger.muxCalls.count == 1)
    }

    @Test func readyToMergeGoesStraightToTheMerge() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let hidden = folder.appending(path: ".osprey-media-\(id.uuidString)")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: hidden.appending(path: "video.mp4"))
        try Data("audio".utf8).write(to: hidden.appending(path: "audio.m4a"))
        let factory = FakeFactory([])
        let merger = FakeMerger()
        let download = makeResumed(savedRecord(folder: folder, id: id, phase: .readyToMerge), id: id, factory: factory, merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(factory.seen.isEmpty)
        #expect(merger.muxCalls.count == 1)
        #expect(exists(folder.appending(path: "My- Video-Clip [abc123].mp4")))
        #expect(!exists(hidden))
    }

    @Test func aDirectPartResumesFromItsSidecar() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let hidden = folder.appending(path: ".osprey-media-\(id.uuidString)")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let saved = try savedAudioState(in: hidden)
        let factory = FakeFactory([PartScript(completeAfter: .max), PartScript(completeAfter: .max)])
        let download = makeResumed(savedRecord(folder: folder, id: id, phase: .downloading), id: id, factory: factory,
                                   merger: FakeMerger())
        let contexts = factory.seen
        #expect(contexts.count == 2)
        #expect(contexts[0].resume == nil)                                  // nothing saved for the video part
        #expect(contexts[1].resume?.map == saved.map)
        #expect(contexts[1].resume?.destination.standardizedFileURL == saved.destination.standardizedFileURL)
        let media = await download.mediaSnapshot()
        #expect(media.parts[1].downloaded == 400 && media.parts[1].total == 1_000)
        await download.discard()
    }

    @Test func theLiveFactoryBuildsAPausedJobFromASidecar() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let hidden = folder.appending(path: ".osprey-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let saved = try savedAudioState(in: hidden)
        let tools = noTools()
        let context = PartFactory.Context(partID: UUID(), pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!,
                                          part: audioPart, file: saved.destination, cookieHeader: nil, speedLimit: nil,
                                          isPrivate: false, tools: tools, extractor: MediaExtractor(tools: tools),
                                          resolverErrors: ResolverErrorLog(), resume: saved)
        let task = PartFactory.live.make(context)
        #expect(task is DownloadJob)
        let snapshot = await task.snapshot()
        #expect(snapshot.state == .paused && snapshot.downloaded == 400 && snapshot.totalSize == 1_000)
        #expect(snapshot.destination?.standardizedFileURL == saved.destination.standardizedFileURL)
    }

    @Test func theRecordDescribesTheDownload() throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let download = makeDownload(folder: folder, factory: FakeFactory([]), merger: FakeMerger())
        let record = download.record(phase: .readyToMerge, warning: nil)
        #expect(record.hiddenFolderID == download.id && download.hiddenFolderID == download.id)
        #expect(record.folder == folder && record.plan == twoPartPlan && record.phase == .readyToMerge)
        #expect(record.video.title == "My: Video/Clip" && record.video.id == "abc123")
    }

    @Test func quittingDuringTheMergeStopsItAndLeavesItReadyToMerge() async throws {
        let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let merger = FakeMerger(delay: .milliseconds(800))
        let download = makeDownload(folder: folder, factory: FakeFactory([PartScript(), PartScript()]), merger: merger)
        await download.start()
        #expect(await waitUntil { await download.mediaSnapshot().phase == .merging })
        await download.suspendForQuit()
        let media = await download.mediaSnapshot()
        #expect(media.phase == .paused)
        #expect(MediaRecord.Phase(media) == .readyToMerge)
        #expect(merger.muxCalls.isEmpty)                                    // the stopped run never got past its delay
        #expect(exists(folder.appending(path: ".osprey-media-\(download.id.uuidString)")))   // the parts stay
        let partials = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.contains(".osprey-partial.") }
        #expect(partials.isEmpty)
        await download.start()                                              // the next launch merges again
        #expect(await waitUntil { await download.mediaSnapshot().phase == .completed })
        #expect(merger.muxCalls.count == 1)
    }
}
