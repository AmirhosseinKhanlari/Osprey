import Foundation
import Testing
@testable import OspreyEngine

@Suite struct ArchivedTaskTests {
    private let fixed = DownloadSnapshot(state: .completed, fileName: "file.zip", totalSize: 4_000, downloaded: 4_000,
                                         bytesPerSecond: 0, segments: [], lanes: [], acceptsRanges: false, etag: nil,
                                         destination: URL(fileURLWithPath: "/tmp/osprey-tests/file.zip"))

    @Test func itOnlyReportsItsSnapshot() async {
        let id = UUID()
        let task = ArchivedTask(id: id, snapshot: fixed)
        await task.start()
        await task.pause()
        await task.setSpeedLimit(1_000)
        #expect(task.id == id)
        #expect(await task.snapshot() == fixed)
    }

    @Test func discardDeletesOnlyItsLeftovers() async throws {
        let dir = TestTemp.unique("archived")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = dir.appending(path: "file.zip")
        let partial = dir.appending(path: "file.zip.slpart")
        let sidecar = dir.appending(path: "file.zip.slpart.json")
        for url in [final, partial, sidecar] { try Data("x".utf8).write(to: url) }
        let task = ArchivedTask(id: UUID(), snapshot: fixed, leftovers: [partial, sidecar])
        await task.discard()
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: sidecar.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: final.path(percentEncoded: false)))
    }

    @Test func discardDecidesWhenItRunsAndSkipsWhatIsInUse() async throws {
        let dir = TestTemp.unique("archived")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appending(path: "file.zip.slpart")
        let sidecar = dir.appending(path: "file.zip.slpart.json")
        let asked = Counter()
        let task = ArchivedTask(id: UUID(), snapshot: fixed) {
            asked.increment()
            return [partial, sidecar]
        }
        #expect(asked.value == 0)                       // nothing is decided when the task is made
        for url in [partial, sidecar] { try Data("x".utf8).write(to: url) }
        // Another listed download uses these paths now: they are its files, not leftovers.
        await task.discard(keeping: [partial, sidecar])
        #expect(asked.value == 1)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: sidecar.path(percentEncoded: false)))
        await task.discard(keeping: [sidecar])
        #expect(!fm.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: sidecar.path(percentEncoded: false)))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
