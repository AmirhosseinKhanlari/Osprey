import Foundation

/// When an active queue is done, and whether its after-finish action may run.
public enum QueueFinish {
    public enum Outcome: Sendable, Equatable {
        /// Still active (or not active at all).
        case none
        /// Nothing left to run and at least one download completed in this activation: deactivate, and run the
        /// after-finish action when `runAction`.
        case finished(runAction: Bool)
        /// Nothing left to run and nothing completed (an empty queue started, or only failures): deactivate quietly.
        case emptied
    }

    /// - `isActive`: a queue the user stopped is no longer active, so it never "finishes".
    /// - `pending`: its downloads queued or running. Failed and paused ones don't count.
    /// - `completedThisActivation`: its downloads that completed since it became active.
    /// - `othersBusy`: downloads of other queues are running or about to start; the action is then skipped.
    public static func check(isActive: Bool, pending: Int, completedThisActivation: Int, othersBusy: Bool) -> Outcome {
        guard isActive, pending == 0 else { return .none }
        guard completedThisActivation > 0 else { return .emptied }
        return .finished(runAction: !othersBusy)
    }
}

/// The power assertions the queues need.
public struct SleepNeeds: Sendable, Equatable {
    /// A keep-awake queue is running: no system sleep.
    public var preventSystemSleep: Bool
    /// A keep-awake queue with waiting downloads starts within 12 h and the Mac is on AC power: no idle sleep (the
    /// display may still sleep).
    public var preventIdleSleep: Bool

    public init(preventSystemSleep: Bool = false, preventIdleSleep: Bool = false) {
        self.preventSystemSleep = preventSystemSleep
        self.preventIdleSleep = preventIdleSleep
    }
}

public enum SleepPlan {
    public static let lookahead: TimeInterval = 12 * 3600

    /// - `busy`: queues with downloads queued or running.
    /// - `waiting`: queues with unfinished downloads waiting to run.
    public static func needs(_ steps: [QueueStep], busy: Set<UUID>, waiting: Set<UUID>, onBattery: Bool, now: Date) -> SleepNeeds {
        var needs = SleepNeeds()
        for step in steps where step.queue.keepAwake {
            switch step.decision {
            case .run:
                if busy.contains(step.queue.id) { needs.preventSystemSleep = true }
            case .wait(let start):
                if !onBattery, waiting.contains(step.queue.id), start.timeIntervalSince(now) <= lookahead {
                    needs.preventIdleSleep = true
                }
            case .hold, .stopped:
                break
            }
        }
        return needs
    }
}
