import Foundation
import Testing
@testable import OspreyEngine

private actor CountingTask: DownloadTask {
    nonisolated let id = UUID()
    private(set) var pauses = 0
    func start() async {}
    func pause() async { pauses += 1 }
    func setSpeedLimit(_ bytesPerSecond: Double?) {}
    func snapshot() -> DownloadSnapshot { .placeholder(fileName: "x") }
    func discard() async {}
}

@Suite struct DownloadTaskTests {
    @Test func quittingPausesATaskByDefault() async {
        let task = CountingTask()
        await task.suspendForQuit()
        #expect(await task.pauses == 1)
    }
}
