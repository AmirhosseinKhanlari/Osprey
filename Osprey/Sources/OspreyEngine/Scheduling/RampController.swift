import Foundation

/// Connections start at 1 and double at most once per second,
/// and only while every active connection is actually receiving data.
public struct RampController: Sendable {
    public let maxConnections: Int
    /// The most connections this download may use: `maxConnections` until the server refuses extra ones
    /// (a per-server connection maximum).
    public private(set) var ceiling: Int
    public private(set) var allowed: Int
    private var lastRamp: TimeInterval

    public init(maxConnections: Int, now: TimeInterval) {
        self.maxConnections = max(1, maxConnections)
        self.ceiling = self.maxConnections
        self.allowed = 1
        self.lastRamp = now
    }

    @discardableResult
    public mutating func update(now: TimeInterval, active: Int, productive: Int, limiterBrake: Bool = false) -> Int {
        guard allowed < ceiling, !limiterBrake,
              now - lastRamp >= 1.0,
              active > 0, productive >= active else { return allowed }
        allowed = min(allowed * 2, ceiling)
        lastRamp = now
        return allowed
    }

    /// Sets the ceiling (clamped to 1…maxConnections) and lowers the current allowance to it.
    public mutating func cap(at limit: Int) {
        ceiling = min(max(1, limit), maxConnections)
        allowed = min(allowed, ceiling)
    }

    /// Lifts a cap: the ceiling goes back to `maxConnections`, and `update` ramps up again from the current allowance.
    public mutating func uncap() {
        ceiling = maxConnections
    }
}
