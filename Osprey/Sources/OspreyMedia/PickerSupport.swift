import Foundation

/// Which picker request is showing. A sheet that closes for an older request (still animating out when a new
/// browser click arrived) must not close the newer one.
public struct PickerRequestTracker: Sendable, Equatable {
    public private(set) var current: UUID?

    public init() {}

    public mutating func open(_ id: UUID) { current = id }

    /// Closes only when `id` is the request showing now. True when it closed.
    @discardableResult
    public mutating func close(ifCurrent id: UUID?) -> Bool {
        guard let id, id == current else { return false }
        current = nil
        return true
    }

    public mutating func close() { current = nil }
}

/// At most `limit` operations at once across every caller (all playlist batches share one, so two playlists
/// don't run four yt-dlp lookups). Waiters run in arrival order.
public actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    /// Runs `operation` once a slot is free. A cancelled caller still takes its turn; the operation itself sees the
    /// cancellation and returns early, and the slot is always given back.
    public func withSlot<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }   // the releaser hands its slot over
        }
        let result = await operation()
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
        return result
    }
}
