import Foundation

/// Pause long enough to pull the average back to the limit,
/// damped when the current speed is well below it, never more than 12 s.
public enum SpeedLimiter {
    public static func pause(bytes: Int64, elapsed: TimeInterval, limit: Double, currentSpeed: Double) -> TimeInterval {
        guard limit > 0, elapsed > 0 else { return 0 }
        let rate = Double(bytes) / elapsed
        guard rate > limit else { return 0 }
        var delay = elapsed * (rate - limit) / limit
        if currentSpeed < limit * 0.5 {
            delay /= 20
        } else if currentSpeed < limit * 0.9 {
            delay /= 2
        }
        return min(delay, 12)
    }

    /// New connections stop opening once the peak speed reaches 85 % of the limit.
    public static func allowsRamp(peakSpeed: Double, limit: Double?) -> Bool {
        guard let limit else { return true }
        return peakSpeed < limit * 0.85
    }
}
