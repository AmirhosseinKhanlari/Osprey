import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct LibraryRecorderTests {
    private struct Rig {
        let dir = TestTemp.unique("recorder")
        let vault = FakeVault()
        let library: DownloadLibrary
        let recorder: LibraryRecorder

        init() {
            library = DownloadLibrary(folder: dir, debounce: .seconds(60))
            recorder = LibraryRecorder(library: library, vault: vault)
        }

        /// What a relaunch would read.
        var onDisk: [DownloadRecord] { DownloadLibrary(folder: dir).load() }
    }

    @Test func anAddedDownloadIsRecordedWithItsCredentials() async {
        let rig = Rig()
        let record = fileRecord()
        #expect(await rig.recorder.added(record, credentials: ["Cookie": "SID=1", "User-Agent": "UA"], isPrivate: false))
        #expect(rig.vault.headers(id: record.id) == ["Cookie": "SID=1"])
        await rig.library.flush()
        #expect(rig.onDisk.first?.hasStoredCredentials == true)
    }

    @Test func privateDownloadsNeverReachTheLibraryOrTheVault() async {
        let rig = Rig()
        let record = fileRecord()
        #expect(!(await rig.recorder.added(record, credentials: ["Cookie": "SID=1"], isPrivate: true)))
        await rig.recorder.changed(record, isPrivate: true, flush: true)
        var done = record
        done.state = .completed
        await rig.recorder.changed(done, isPrivate: true, flush: true)
        await rig.recorder.removed(id: record.id, isPrivate: true)
        await rig.library.flush()
        #expect(rig.vault.calls == 0)
        #expect(await rig.library.writeCount == 0)
        #expect(!exists(rig.dir.appending(path: "library.json")))
    }

    @Test func aPauseIsFlushedAtOnce() async {
        let rig = Rig()
        let record = fileRecord()
        await rig.recorder.changed(record, isPrivate: false, flush: true)
        #expect(rig.onDisk == [record])
        #expect(rig.vault.calls == 0)                       // a pause keeps the credentials
    }

    @Test func completionIsFlushedAndDeletesTheCredentials() async {
        let rig = Rig()
        var record = fileRecord()
        await rig.recorder.added(record, credentials: ["Cookie": "SID=1"], isPrivate: false)
        record.state = .completed
        await rig.recorder.changed(record, isPrivate: false, flush: true)
        #expect(rig.onDisk.first?.state == .completed)
        #expect(rig.vault.headers(id: record.id).isEmpty)
    }

    @Test func removalDeletesTheRecordAndTheCredentials() async {
        let rig = Rig()
        let record = fileRecord()
        await rig.recorder.added(record, credentials: ["Authorization": "Bearer t"], isPrivate: false)
        await rig.library.flush()
        await rig.recorder.removed(id: record.id, isPrivate: false)
        #expect(rig.onDisk.isEmpty)
        #expect(rig.vault.storedIDs.isEmpty)
    }

    @Test func aChangeAfterARemovalLeavesNothing() async {
        let rig = Rig()
        var record = fileRecord()
        await rig.recorder.added(record, credentials: ["Cookie": "SID=1"], isPrivate: false)
        await rig.library.flush()
        await rig.recorder.removed(id: record.id, isPrivate: false)
        // A refresh that awaited the task across the removal reports the item once more.
        record.state = .failed("x")
        await rig.recorder.changed(record, isPrivate: false, flush: true)
        #expect(rig.onDisk.isEmpty)
        #expect(rig.vault.storedIDs.isEmpty)
    }

    @Test func anAddAfterARemovalStoresNothing() async {
        let rig = Rig()
        let record = fileRecord()
        await rig.recorder.removed(id: record.id, isPrivate: false)
        #expect(!(await rig.recorder.added(record, credentials: ["Cookie": "SID=1"], isPrivate: false)))
        await rig.library.flush()
        #expect(rig.onDisk.isEmpty)
        #expect(rig.vault.storedIDs.isEmpty)
    }

    @Test func pruningKeepsListedDownloadsAndThoseAddedSinceLaunch() async throws {
        let rig = Rig()
        let orphan = UUID(), listed = UUID()
        try rig.vault.store(id: orphan, headers: ["Cookie": "a=1"])
        try rig.vault.store(id: listed, headers: ["Cookie": "b=1"])
        let fresh = fileRecord()
        await rig.recorder.added(fresh, credentials: ["Cookie": "c=1"], isPrivate: false)    // a capture at launch
        await rig.recorder.pruneCredentials(keeping: [listed])
        #expect(rig.vault.storedIDs == [listed, fresh.id])
    }

    @Test func credentialsAreReadThroughTheRecorder() async {
        let rig = Rig()
        let record = fileRecord()
        await rig.recorder.added(record, credentials: ["Authorization": "Bearer t"], isPrivate: false)
        #expect(await rig.recorder.credentials(id: record.id) == ["Authorization": "Bearer t"])
        #expect(await rig.recorder.credentials(id: UUID()).isEmpty)
    }
}
