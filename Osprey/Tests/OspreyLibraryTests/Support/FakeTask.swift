import Foundation
import OspreyEngine

/// A record of what happened, in order, across tasks and closures.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func append(_ event: String) { lock.withLock { _events.append(event) } }
}

/// Counts pauses and discards. Quitting reaches `pause()` through `DownloadTask`'s default `suspendForQuit()`.
/// `hang` makes `pause()` take that long (a task that won't stop).
actor FakeTask: DownloadTask {
    nonisolated let id = UUID()
    private(set) var pauses = 0
    private(set) var discards = 0
    private let hang: Duration?
    private let log: EventLog?

    init(hang: Duration? = nil, log: EventLog? = nil) {
        self.hang = hang
        self.log = log
    }

    func start() async {}

    func pause() async {
        pauses += 1
        if let hang { try? await Task.sleep(for: hang) }
        log?.append("pause")
    }

    func setSpeedLimit(_ bytesPerSecond: Double?) {}

    func snapshot() -> DownloadSnapshot { .placeholder(fileName: "fake") }

    func discard() async {
        discards += 1
        log?.append("discard")
    }
}
