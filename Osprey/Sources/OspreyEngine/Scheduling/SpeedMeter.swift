import Foundation

/// Sliding-window throughput meter with 100 ms buckets.
public struct SpeedMeter: Sendable {
    private struct Bucket: Sendable {
        let time: TimeInterval
        var bytes: Int64
    }

    public let window: TimeInterval
    private let startedAt: TimeInterval
    private var buckets: [Bucket] = []

    public init(window: TimeInterval = 3, startedAt: TimeInterval) {
        self.window = window
        self.startedAt = startedAt
    }

    public mutating func add(_ bytes: Int64, at time: TimeInterval) {
        guard bytes > 0 else { return }
        let slot = (time * 10).rounded(.down) / 10
        if let last = buckets.indices.last, buckets[last].time == slot {
            buckets[last].bytes += bytes
        } else {
            buckets.append(Bucket(time: slot, bytes: bytes))
        }
        while let first = buckets.first, first.time <= time - window { buckets.removeFirst() }
    }

    public func windowStats(at now: TimeInterval) -> (bytes: Int64, elapsed: TimeInterval) {
        let bytes = buckets.filter { $0.time > now - window }.reduce(Int64(0)) { $0 + $1.bytes }
        return (bytes, min(window, max(now - startedAt, 0)))
    }

    public func bytesPerSecond(at now: TimeInterval) -> Double {
        let stats = windowStats(at: now)
        return stats.elapsed > 0 ? Double(stats.bytes) / stats.elapsed : 0
    }
}
