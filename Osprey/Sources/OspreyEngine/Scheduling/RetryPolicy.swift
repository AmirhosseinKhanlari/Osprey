import Foundation

/// The wait grows by 2 s per restart up to 30 s. It honours
/// `Retry-After` (capped at 5 min) and stops after `maxAttempts` consecutive failures.
public struct RetryPolicy: Sendable, Equatable {
    public var step: TimeInterval
    public var cap: TimeInterval
    public var maxAttempts: Int?

    public init(step: TimeInterval = 2, cap: TimeInterval = 30, maxAttempts: Int? = 20) {
        self.step = step
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 0), 300) }
        return min(step * Double(max(attempt, 1)), cap)
    }

    public func canRetry(attempt: Int) -> Bool {
        guard let maxAttempts else { return true }
        return attempt < maxAttempts
    }
}
