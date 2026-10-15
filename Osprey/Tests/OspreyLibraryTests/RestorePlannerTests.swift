import Foundation
import Testing
import OspreyEngine
@testable import OspreyLibrary
@testable import OspreyMedia

@Suite struct RestorePlannerTests {
    private let destination = URL(fileURLWithPath: "/tmp/osprey-tests/Archives/file.zip")

    private func saved(for destination: URL) -> ResumeState {
        var map = SegmentMap(totalSize: 4_000)
        map.record(1_000, for: 0)
        return ResumeState(url: URL(string: "https://cdn.files.example/file.zip")!, destination: destination,
                           headers: ["User-Agent": "UA"], totalSize: 4_000, etag: "\"v1\"", lastModified: nil,
                           acceptsRanges: true, map: map, originalURL: URL(string: "https://files.example/file.zip")!)
    }

    @Test func anUnfinishedFileWithASidecarResumesPaused() async {
        let record = fileRecord(destination: destination)
        let state = saved(for: destination)
        var checked: [URL] = []
        let action = RestorePlanner.plan(record, fileExists: { _ in false },
                                         sidecarExists: { checked.append($0); return true }, loadSidecar: { _ in state })
        #expect(action == .resumeFile(state))
        #expect(checked == [destination.appendingPathExtension("slpart").appendingPathExtension("json")])
        // What the app builds from it: a paused job showing the saved progress.
        let job = DownloadJob(id: record.id, resuming: state)
        let snapshot = await job.snapshot()
        #expect(snapshot.state == .paused)
        #expect(snapshot.downloaded == 1_000 && snapshot.totalSize == 4_000)
    }

    @Test func anUnfinishedFileWithoutASidecarStartsOver() {
        let record = fileRecord(destination: destination)
        #expect(RestorePlanner.plan(record, fileExists: { _ in true }, sidecarExists: { _ in false }) == .restartFile)
        let shown = RestorePlanner.resumableSnapshot(for: record)
        #expect(shown.state == .paused && shown.downloaded == 1_000 && shown.totalSize == 4_000)
        #expect(shown.fileName == "file.zip" && shown.destination == nil)
    }

    @Test func anUnreadableOrForeignSidecarStartsOver() {
        let record = fileRecord(destination: destination)
        #expect(RestorePlanner.plan(record, fileExists: { _ in false }, sidecarExists: { _ in true },
                                    loadSidecar: { _ in nil }) == .restartFile)
        let other = saved(for: URL(fileURLWithPath: "/tmp/osprey-tests/Archives/other.zip"))
        #expect(RestorePlanner.plan(record, fileExists: { _ in false }, sidecarExists: { _ in true },
                                    loadSidecar: { _ in other }) == .restartFile)
        var elsewhere = saved(for: destination)             // same name, another download's URL
        elsewhere.url = URL(string: "https://other.example/file.zip")!
        elsewhere.originalURL = elsewhere.url
        #expect(RestorePlanner.plan(record, fileExists: { _ in false }, sidecarExists: { _ in true },
                                    loadSidecar: { _ in elsewhere }) == .restartFile)
    }

    @Test func aSidecarMatchesByDestinationAndEitherURL() {
        let record = fileRecord(destination: destination)
        var state = saved(for: destination)
        #expect(RestorePlanner.sidecarMatches(state, record))                     // originalURL is the record's
        state.originalURL = URL(string: "https://mirror.example/file.zip")!
        state.url = record.url
        #expect(RestorePlanner.sidecarMatches(state, record))                     // or the final URL is
        state.url = URL(string: "https://cdn.files.example/file.zip")!
        #expect(!RestorePlanner.sidecarMatches(state, record))
        #expect(!RestorePlanner.sidecarMatches(saved(for: destination.deletingLastPathComponent().appending(path: "b.zip")),
                                               record))
    }

    @Test func anUnfinishedVideoResumesItsParts() throws {
        let record = mediaDownloadRecord(phase: .downloading)
        let media = try #require(record.media)
        #expect(RestorePlanner.plan(record, fileExists: { _ in false }, sidecarExists: { _ in false }) == .resumeMedia(media))
        #expect(media.phase == .downloading)
    }

    @Test func aVideoReadyToMergeResumesAtTheMerge() {
        let record = mediaDownloadRecord(phase: .readyToMerge)
        guard case .resumeMedia(let media) = RestorePlanner.plan(record, fileExists: { _ in false },
                                                                 sidecarExists: { _ in false }) else {
            Issue.record("expected .resumeMedia")
            return
        }
        #expect(media.phase == .readyToMerge)
        #expect(media.hiddenFolderID == record.id)
    }

    @Test func aCompletedFileThatIsThereIsListedAsFinished() {
        let record = fileRecord(state: .completed, destination: destination)
        let target = destination
        #expect(RestorePlanner.plan(record, fileExists: { $0 == target }, sidecarExists: { _ in false })
                == .archived(missingFile: false))
        let shown = RestorePlanner.archivedSnapshot(for: record, missingFile: false)
        #expect(shown.state == .completed && shown.destination == destination && shown.downloaded == 4_000)
        #expect(RestorePlanner.leftovers(for: record).isEmpty)
    }

    @Test func aCompletedFileThatIsGoneShowsFileMissing() {
        let record = fileRecord(state: .completed, destination: destination)
        #expect(RestorePlanner.plan(record, fileExists: { _ in false }, sidecarExists: { _ in false })
                == .archived(missingFile: true))
        let shown = RestorePlanner.archivedSnapshot(for: record, missingFile: true)
        #expect(shown.state == .completed)
        #expect(shown.destination == nil)              // no Open or Show in Finder for a file that isn't there
    }

    @Test func aFailedFileWithItsDataResumesShowingTheFailure() {
        let record = fileRecord(state: .failed("The network connection was lost."), destination: destination)
        let state = saved(for: destination)
        #expect(RestorePlanner.plan(record, fileExists: { _ in true }, sidecarExists: { _ in true }, loadSidecar: { _ in state })
                == .resumeFile(state))
        let shown = RestorePlanner.resumableSnapshot(for: record)
        #expect(shown.state == .failed("The network connection was lost."))
        #expect(shown.downloaded == 1_000 && shown.totalSize == 4_000 && shown.destination == nil)
    }

    @Test func aFailedFileWithoutUsableDataIsListedForRetry() {
        let record = fileRecord(state: .failed("The server answered HTTP 500."), destination: destination)
        #expect(RestorePlanner.plan(record, fileExists: { _ in true }, sidecarExists: { _ in false })
                == .archived(missingFile: false))
        var foreign = saved(for: destination)
        foreign.url = URL(string: "https://other.example/x")!
        foreign.originalURL = foreign.url
        #expect(RestorePlanner.plan(record, fileExists: { _ in true }, sidecarExists: { _ in true },
                                    loadSidecar: { _ in foreign }) == .archived(missingFile: false))
        let shown = RestorePlanner.archivedSnapshot(for: record, missingFile: false)
        #expect(shown.state == .failed("The server answered HTTP 500.") && shown.destination == nil)
    }

    @Test func aFailedVideoWithItsFolderResumesElseIsListedForRetry() throws {
        let folder = URL(fileURLWithPath: "/tmp/osprey-tests/Video")
        let video = mediaDownloadRecord(state: .failed("x"), folder: folder)
        let media = try #require(video.media)
        let hidden = folder.appending(path: ".osprey-media-\(video.id.uuidString)", directoryHint: .isDirectory)
        #expect(RestorePlanner.plan(video, fileExists: { $0.standardizedFileURL == hidden.standardizedFileURL },
                                    sidecarExists: { _ in false }) == .resumeMedia(media))
        #expect(RestorePlanner.plan(video, fileExists: { _ in false }, sidecarExists: { _ in false })
                == .archived(missingFile: false))
    }

    @Test func leftoversAreAFailedFilesOwnDataOnly() {
        let record = fileRecord(state: .failed("The server answered HTTP 500."), destination: destination)
        let part = destination.appendingPathExtension("slpart")
        #expect(RestorePlanner.leftovers(for: record, loadSidecar: { _ in saved(for: destination) })
                == [part, part.appendingPathExtension("json")])
        #expect(RestorePlanner.leftovers(for: record, loadSidecar: { _ in nil }).isEmpty)
        // A new download took the name again: its sidecar has another URL, so its files are not this record's.
        var newer = saved(for: destination)
        newer.url = URL(string: "https://other.example/file.zip")!
        newer.originalURL = newer.url
        #expect(RestorePlanner.leftovers(for: record, loadSidecar: { _ in newer }).isEmpty)
        #expect(RestorePlanner.leftovers(for: fileRecord(state: .completed), loadSidecar: { _ in saved(for: destination) })
                .isEmpty)
        let folder = URL(fileURLWithPath: "/tmp/osprey-tests/Video")
        let video = mediaDownloadRecord(state: .failed("x"), folder: folder)
        #expect(RestorePlanner.leftovers(for: video, loadSidecar: { _ in nil })
                == [folder.appending(path: ".osprey-media-\(video.id.uuidString)", directoryHint: .isDirectory)])
    }

    @Test func aFileRenamedJustBeforeACrashIsFinished() {
        let record = fileRecord(destination: destination)            // saved paused, 4 000 bytes expected
        let target = destination
        #expect(RestorePlanner.plan(record, fileExists: { $0 == target }, sidecarExists: { _ in false },
                                    fileSize: { _ in 4_000 }) == .archived(missingFile: false))
        #expect(RestorePlanner.plan(record, fileExists: { $0 == target }, sidecarExists: { _ in false },
                                    fileSize: { _ in 3_999 }) == .restartFile)
        // Size unknown: it must have received bytes (it was probed) and the file holds at least those.
        var unknown = record
        unknown.totalSize = nil
        #expect(RestorePlanner.plan(unknown, fileExists: { $0 == target }, sidecarExists: { _ in false },
                                    fileSize: { _ in 1_500 }) == .archived(missingFile: false))
        unknown.downloaded = 0                                       // never probed: the name may be another file's
        #expect(RestorePlanner.plan(unknown, fileExists: { $0 == target }, sidecarExists: { _ in false },
                                    fileSize: { _ in 1_500 }) == .restartFile)

        let at = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let finished = RestorePlanner.finished(record, fileSize: 4_000, at: at)
        #expect(finished.state == .completed && finished.completedAt == at && finished.downloaded == 4_000)
        let shown = RestorePlanner.archivedSnapshot(for: finished, missingFile: false)
        #expect(shown.state == .completed && shown.destination == destination)
    }

    @Test func theLaunchKeepsWhatResumableDownloadsNeed() throws {
        let paused = fileRecord()
        let video = mediaDownloadRecord()
        let failedFile = fileRecord(state: .failed("lost"))
        let failedVideo = mediaDownloadRecord(state: .failed("x"))
        let goneVideo = mediaDownloadRecord(state: .failed("x"))
        let actions: [UUID: RestoreAction] = [
            paused.id: .restartFile,
            video.id: .resumeMedia(try #require(video.media)),
            failedFile.id: .resumeFile(saved(for: destination)),
            failedVideo.id: .resumeMedia(try #require(failedVideo.media)),
            goneVideo.id: .archived(missingFile: false),
            UUID(): .archived(missingFile: true),
        ]
        #expect(RestorePlanner.credentialIDsToKeep(actions) == [paused.id, video.id, failedFile.id, failedVideo.id])
        #expect(RestorePlanner.hiddenFolderIDsToKeep(actions.values) == [video.id, failedVideo.id])
    }
}
