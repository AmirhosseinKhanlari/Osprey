import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct QueueStoreTests {
    /// 2026-10-15T12:00:00Z.
    private let noon = Date(timeIntervalSince1970: 1_792_065_600)

    @Test func aFirstLaunchHasMainAndLater() {
        let queues = QueueStore(folder: TestTemp.unique("queues")).load()
        #expect(queues.map(\.id) == [Queue.mainID, Queue.laterID])
        #expect(queues[0].isMain && queues[0].name == "Main" && queues[0].maxConcurrent == 4)
        #expect(!queues[1].isMain && queues[1].name == "Later" && queues[1].maxConcurrent == 2)
        #expect(queues[1].schedule == .manual && queues[1].afterFinish == .nothing && !queues[1].isActive)
    }

    @Test func queuesRoundTripThroughTheFile() throws {
        let store = QueueStore(folder: TestTemp.unique("queues"))
        let nightly = Queue(name: "Nightly", maxConcurrent: 3, schedule: .daily(time: hm(2), weekdays: weekdaysOnly),
                            stopTime: hm(6, 30), onlyOnWiFi: true, onlyOnAC: true, keepAwake: true, afterFinish: .sleep,
                            isActive: true, lastStartedAt: noon)
        let once = Queue(name: "Once", schedule: .once(start: noon), afterFinish: .shutdown)
        try store.save([.main, nightly, once])
        #expect(store.load() == [.main, nightly, once])
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains(#""version":1"#))
    }

    @Test func theFileIsWrittenAtomicallyAndPrivately() throws {
        let store = QueueStore(folder: TestTemp.unique("queues"))
        try store.save(QueueStore.defaults)
        try store.save(QueueStore.defaults)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path(percentEncoded: false))[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: store.folder.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path(percentEncoded: false))
        #expect(names == ["queues.json"])
    }

    @Test func aCorruptFileIsMovedAsideAndLoadsTheDefaults() throws {
        let dir = TestTemp.unique("queues")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appending(path: "queues.json"))
        let stamp = noon
        #expect(QueueStore(folder: dir, now: { stamp }).load() == QueueStore.defaults)
        #expect(!exists(dir.appending(path: "queues.json")))
        let aside = dir.appending(path: "queues.corrupt-20261015T120000Z.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
    }

    @Test func aFileThatCantBeReadIsMovedAsideSoASaveNeverOverwritesIt() throws {
        let dir = TestTemp.unique("queues")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "queues.json")
        try Data(#"{"version":1,"queues":[]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))
        let stamp = noon
        let store = QueueStore(folder: dir, now: { stamp })
        #expect(store.load() == QueueStore.defaults)
        #expect(!exists(file))
        let aside = dir.appending(path: "queues.unreadable-20261015T120000Z.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path(percentEncoded: false))
        try store.save(QueueStore.defaults)                            // the user's file is still there
        #expect(try String(contentsOf: aside, encoding: .utf8) == #"{"version":1,"queues":[]}"#)
    }

    @Test func anotherVersionIsMovedAsideAndLoadsTheDefaults() throws {
        let dir = TestTemp.unique("queues")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":2,"queues":[]}"#.utf8).write(to: dir.appending(path: "queues.json"))
        let stamp = noon
        #expect(QueueStore(folder: dir, now: { stamp }).load() == QueueStore.defaults)
        #expect(exists(dir.appending(path: "queues.v2-20261015T120000Z.json")))
    }

    @Test func mainIsAlwaysFirstUnscheduledAndPresent() throws {
        let store = QueueStore(folder: TestTemp.unique("queues"))
        let later = Queue.later
        var main = Queue.main
        main.schedule = .daily(time: hm(2), weekdays: everyDay)        // Main can't be scheduled
        main.stopTime = hm(3)
        main.onlyOnWiFi = true
        try store.save([later, main, later])
        let loaded = store.load()
        #expect(loaded.map(\.id) == [Queue.mainID, Queue.laterID])
        #expect(loaded[0].schedule == .manual && loaded[0].stopTime == nil && !loaded[0].onlyOnWiFi)
        try store.save([later])                                        // no Main at all
        #expect(store.load().map(\.id) == [Queue.mainID, Queue.laterID])
    }

    @Test func filesAtOnceIsClampedWhenUsed() {
        #expect(Queue(name: "A", maxConcurrent: 0).slots == 1)
        #expect(Queue(name: "B", maxConcurrent: 12).slots == 8)
        #expect(Queue(name: "C", maxConcurrent: 3).slots == 3)
    }
}
