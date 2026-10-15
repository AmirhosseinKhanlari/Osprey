import Foundation
import OspreyEngine

/// One download as quitting sees it.
public struct QuitItem: Sendable {
    public var task: any DownloadTask
    public var isPrivate: Bool

    public init(task: any DownloadTask, isPrivate: Bool) {
        self.task = task
        self.isPrivate = isPrivate
    }
}

/// Quitting:
/// 1. Every download stops at once, side by side: `suspendForQuit()`, or `discard()` for a private one, which deletes
///    its partial files.
/// 2. `persist` saves the list.
/// 3. `flush` writes it.
///
/// All of it within `timeout`. When the time runs out, `flush` still writes what was saved, and the app quits anyway:
/// what is already on disk is enough to resume.
public enum QuitSequence {
    public static let timeout: Duration = .seconds(3)

    /// True when everything finished within `timeout`.
    public static func run(_ items: [QuitItem], timeout: Duration = QuitSequence.timeout,
                           persist: @escaping @Sendable () async -> Void,
                           flush: @escaping @Sendable () async -> Void) async -> Bool {
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask {
                        if item.isPrivate {
                            await item.task.discard()
                        } else {
                            await item.task.suspendForQuit()
                        }
                    }
                }
            }
            await persist()
            await flush()
        }
        let finished = await finishes(work, within: timeout)
        if !finished { await flush() }
        return finished
    }

    /// Waits for `work` or the timeout, whichever comes first. `work` is not cancelled: a task that won't stop simply
    /// isn't waited for.
    private static func finishes(_ work: Task<Void, Never>, within timeout: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                once.resume(false)
            }
            Task {
                await work.value
                once.resume(true)
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation the first time only.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
