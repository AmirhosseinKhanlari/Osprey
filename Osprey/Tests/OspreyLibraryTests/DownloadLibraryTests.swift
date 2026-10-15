import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct DownloadLibraryTests {
    /// 2026-10-14T12:00:00Z.
    private let noon = Date(timeIntervalSince1970: 1_791_979_200)

    @Test func recordsRoundTripThroughTheFile() async {
        let dir = TestTemp.unique("library")
        let library = DownloadLibrary(folder: dir, debounce: .seconds(60))
        let older = fileRecord(addedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        let newer = mediaDownloadRecord(addedAt: Date(timeIntervalSinceReferenceDate: 2_000), folder: dir)
        await library.update(older)
        await library.update(newer)
        await library.flush()
        #expect(DownloadLibrary(folder: dir).load() == [newer, older])          // newest first
    }

    @Test func severalUpdatesWithinTheWindowCauseOneWrite() async throws {
        let dir = TestTemp.unique("library")
        let library = DownloadLibrary(folder: dir, debounce: .milliseconds(200))
        var record = fileRecord()
        for downloaded in [Int64(10), 20, 30] {
            record.downloaded = downloaded
            await library.update(record)
        }
        #expect(await library.writeCount == 0)
        #expect(await waitUntil(timeout: 3) { await library.writeCount == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await library.writeCount == 1)
        #expect(DownloadLibrary(folder: dir).load().first?.downloaded == 30)
    }

    @Test func flushWritesAtOnce() async {
        let dir = TestTemp.unique("library")
        let library = DownloadLibrary(folder: dir, debounce: .seconds(60))
        let record = fileRecord()
        await library.update(record)
        await library.flush()
        #expect(await library.writeCount == 1)
        #expect(DownloadLibrary(folder: dir).load() == [record])
    }

    @Test func aRemovedRecordIsGoneAfterTheNextWrite() async {
        let dir = TestTemp.unique("library")
        let library = DownloadLibrary(folder: dir, debounce: .seconds(60))
        let kept = fileRecord(), removed = fileRecord()
        await library.update(kept)
        await library.update(removed)
        await library.flush()
        await library.remove(id: removed.id)
        await library.flush()
        #expect(DownloadLibrary(folder: dir).load() == [kept])
    }

    @Test func anUpdateAfterARemovalIsIgnored() async {
        let dir = TestTemp.unique("library")
        let library = DownloadLibrary(folder: dir, debounce: .seconds(60))
        let record = fileRecord()
        await library.update(record)
        await library.flush()
        await library.remove(id: record.id)
        await library.flush()
        await library.update(record)                      // a late save from a refresh that began before the removal
        await library.flush()
        #expect(DownloadLibrary(folder: dir).load().isEmpty)
        let early = fileRecord()
        await library.remove(id: early.id)                // removed before its first save arrived
        await library.update(early)
        await library.flush()
        #expect(DownloadLibrary(folder: dir).load().isEmpty)
    }

    @Test func staleTemporaryFilesAreDeletedAtLaunch() throws {
        let dir = TestTemp.unique("library")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appending(path: ".library.json.\(UUID().uuidString).tmp")
        let other = dir.appending(path: "notes.tmp")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: other)
        _ = DownloadLibrary(folder: dir)
        #expect(!exists(stale))
        #expect(exists(other))
    }

    @Test func aFailedWriteIsRetriedWithBackoff() async throws {
        let dir = TestTemp.unique("library")
        // A plain file where the folder should be: every write fails until it is gone.
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir)
        let library = DownloadLibrary(folder: dir, debounce: .milliseconds(20))
        let record = fileRecord()
        await library.update(record)
        #expect(await waitUntil(timeout: 3) { await library.failedWrites >= 2 })
        #expect(await library.writeCount == 0)
        try FileManager.default.removeItem(at: dir)
        #expect(await waitUntil(timeout: 5) { await library.writeCount == 1 })
        #expect(await library.failedWrites == 0)
        #expect(DownloadLibrary(folder: dir).load() == [record])
    }

    @Test func retriesStopAtTheLimit() async throws {
        let dir = TestTemp.unique("library")
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir)
        let library = DownloadLibrary(folder: dir, debounce: .milliseconds(1))
        await library.update(fileRecord())
        #expect(await waitUntil(timeout: 5) { await library.failedWrites == DownloadLibrary.maxWriteRetries + 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await library.failedWrites == DownloadLibrary.maxWriteRetries + 1)
        try FileManager.default.removeItem(at: dir)
    }

    @Test func aCorruptFileIsMovedAsideAndLoadsEmpty() throws {
        let dir = TestTemp.unique("library")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appending(path: "library.json"))
        let stamp = noon
        let library = DownloadLibrary(folder: dir, now: { stamp })
        #expect(library.load().isEmpty)
        #expect(!exists(dir.appending(path: "library.json")))
        let aside = dir.appending(path: "library.corrupt-20261014T120000Z.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
    }

    @Test func anUnknownVersionIsMovedAsideAndLoadsEmpty() throws {
        let dir = TestTemp.unique("library")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":2,"items":[]}"#.utf8).write(to: dir.appending(path: "library.json"))
        let stamp = noon
        let library = DownloadLibrary(folder: dir, now: { stamp })
        #expect(library.load().isEmpty)
        #expect(!exists(dir.appending(path: "library.json")))
        #expect(exists(dir.appending(path: "library.v2-20261014T120000Z.json")))
    }

    @Test func theFileAndFolderArePrivateToTheUser() async throws {
        let dir = TestTemp.unique("library")
        let library = DownloadLibrary(folder: dir, debounce: .seconds(60))
        await library.update(fileRecord())
        await library.flush()
        let fileMode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "library.json").path(percentEncoded: false))[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: dir.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func anUnreadableRecordIsSkippedAndTheRestLoad() throws {
        let dir = TestTemp.unique("library")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = fileRecord()
        var broken = mediaDownloadRecord()
        broken.media = nil                                    // a video without its media record can't be rebuilt
        let items = String(decoding: try JSONEncoder().encode([good, broken]), as: UTF8.self)
        let json = #"{"version":1,"items":"# + items + "}"
        try Data(json.utf8).write(to: dir.appending(path: "library.json"))
        #expect(DownloadLibrary(folder: dir).load() == [good])
        #expect(exists(dir.appending(path: "library.json")))  // a skipped record doesn't move the file aside
    }
}
