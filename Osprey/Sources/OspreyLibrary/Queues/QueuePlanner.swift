import Foundation

/// Why an active queue isn't running.
public enum HoldReason: Sendable, Equatable {
    /// Only on Wi-Fi, and the network is expensive (a phone hotspot) or constrained (Low Data Mode).
    case wifi
    /// Only when plugged in, and the Mac is on battery.
    case power
    /// No network at all: every queue but Main holds rather than failing its downloads.
    case offline
}

/// What a queue does now.
public enum QueueDecision: Sendable, Equatable {
    /// Start its downloads, up to its `slots`.
    case run
    /// Not active; its schedule starts it at `nextStart`.
    case wait(nextStart: Date)
    /// Active, but a condition isn't met; it continues by itself once it is.
    case hold(reason: HoldReason)
    /// Not active, and nothing will start it but the user.
    case stopped
}

/// The network and power state the conditions read.
public struct QueueConditions: Sendable, Equatable {
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var onBattery: Bool
    /// No usable network path.
    public var isOffline: Bool

    public init(isExpensive: Bool = false, isConstrained: Bool = false, onBattery: Bool = false, isOffline: Bool = false) {
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.onBattery = onBattery
        self.isOffline = isOffline
    }
}

/// One queue after a planning pass: its new state, its decision, and whether a start began just now.
public struct QueueStep: Sendable, Equatable {
    public var queue: Queue
    public var decision: QueueDecision
    /// A scheduled start activated it in this pass: its waiting downloads should run.
    public var started: Bool
}

/// The scheduler's rules, without timers or system state: everything comes in as `now`, a `Calendar` (its time zone
/// decides wall-clock times and DST) and the conditions.
///
/// - Main always runs.
/// - A manual queue runs while it is active.
/// - `.once` and `.daily` activate at their start instant. A start missed while Osprey was closed or the Mac slept
///   still counts while `now` is inside its window: from the start to the stop time, or without one to the end of
///   that day (`.daily`) or 24 h (`.once`). `lastStartedAt` marks starts already handled.
/// - An active queue with a stop time deactivates at the first stop time after it started.
/// - Unmet conditions hold an active queue, and so does being offline (every queue but Main).
public enum QueuePlanner {
    public static func step(_ queue: Queue, now: Date, calendar: Calendar, conditions: QueueConditions) -> QueueStep {
        let next = advance(queue, now: now, calendar: calendar)
        let started = next.isActive && (!queue.isActive || next.lastStartedAt != queue.lastStartedAt)
        return QueueStep(queue: next, decision: evaluate(next, now: now, calendar: calendar, conditions: conditions),
                         started: started && !next.isMain)
    }

    /// The decision for a queue `advance` already brought up to `now`.
    public static func evaluate(_ queue: Queue, now: Date, calendar: Calendar, conditions: QueueConditions) -> QueueDecision {
        if queue.isMain { return .run }
        guard queue.isActive else {
            if let start = nextStart(queue, after: now, calendar: calendar) { return .wait(nextStart: start) }
            return .stopped
        }
        if conditions.isOffline { return .hold(reason: .offline) }
        if queue.onlyOnWiFi && (conditions.isExpensive || conditions.isConstrained) { return .hold(reason: .wifi) }
        if queue.onlyOnAC && conditions.onBattery { return .hold(reason: .power) }
        return .run
    }

    /// `queue` at `now`: past its stop time it deactivates; a due start (missed or not) activates it.
    public static func advance(_ queue: Queue, now: Date, calendar: Calendar) -> Queue {
        guard !queue.isMain else { return queue }
        var queue = queue
        if queue.isActive, let started = queue.lastStartedAt,
           let stop = stopInstant(queue, after: started, calendar: calendar), now >= stop {
            queue.isActive = false
        }
        if !queue.isActive, let start = dueStart(queue, now: now, calendar: calendar) {
            queue.isActive = true
            queue.lastStartedAt = start
        }
        return queue
    }

    /// The first start instant strictly after `after`, or nil (manual, Main, a past `.once`, no weekdays).
    public static func nextStart(_ queue: Queue, after: Date, calendar: Calendar) -> Date? {
        guard !queue.isMain else { return nil }
        switch queue.schedule {
        case .manual:
            return nil
        case .once(let start):
            return start > after ? start : nil
        case .daily(let time, let weekdays):
            let today = calendar.startOfDay(for: after)
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      weekdays.contains(calendar.component(.weekday, from: day)),
                      let start = instant(minutes: time, on: day, calendar: calendar), start > after else { continue }
                return start
            }
            return nil
        }
    }

    /// When the timer should next fire: the soonest start of an inactive queue or stop of an active one.
    public static func nextEvent(_ queues: [Queue], now: Date, calendar: Calendar) -> Date? {
        queues.compactMap { queue -> Date? in
            if queue.isActive {
                guard let started = queue.lastStartedAt else { return nil }
                return stopInstant(queue, after: started, calendar: calendar)
            }
            return nextStart(queue, after: now, calendar: calendar)
        }.min()
    }

    /// The first stop time strictly after `started`, or nil without a stop time. A stop time at or before the start's
    /// time of day falls on the next day (a window across midnight).
    public static func stopInstant(_ queue: Queue, after started: Date, calendar: Calendar) -> Date? {
        guard !queue.isMain, let stop = queue.stopTime else { return nil }
        let day = calendar.startOfDay(for: started)
        if let sameDay = instant(minutes: stop, on: day, calendar: calendar), sameDay > started { return sameDay }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        return instant(minutes: stop, on: nextDay, calendar: calendar)
    }

    /// The latest start at or before `now` that hasn't been handled and whose window still holds `now`.
    static func dueStart(_ queue: Queue, now: Date, calendar: Calendar) -> Date? {
        let candidates: [Date]
        switch queue.schedule {
        case .manual:
            return nil
        case .once(let start):
            candidates = [start]
        case .daily(let time, let weekdays):
            let today = calendar.startOfDay(for: now)
            candidates = [0, -1].compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
                return instant(minutes: time, on: day, calendar: calendar)
            }
        }
        return candidates.first { start in
            guard start <= now, queue.lastStartedAt.map({ $0 < start }) ?? true,
                  let end = windowEnd(queue, start: start, calendar: calendar) else { return false }
            return now < end
        }
    }

    /// Until the stop time; without one, the end of the start's day (`.daily`) or 24 h later (`.once`).
    static func windowEnd(_ queue: Queue, start: Date, calendar: Calendar) -> Date? {
        if let stop = stopInstant(queue, after: start, calendar: calendar) { return stop }
        switch queue.schedule {
        case .daily: return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
        case .once, .manual: return start.addingTimeInterval(24 * 3600)
        }
    }

    /// `minutes` after midnight on `day`'s date. A time the clocks skip (2:30 AM when DST begins) gives the next time
    /// that exists (3:00 AM); a time that happens twice (1:30 AM when DST ends) gives the first.
    public static func instant(minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: calendar.startOfDay(for: day),
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// The minutes since midnight of `date`'s wall-clock time.
    public static func minutes(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// `queue` stopped by the user, or finished, at `now`: inactive, and every start up to `now` counts as handled, so a
    /// start that passed while it ran doesn't start it again at once.
    public static func deactivated(_ queue: Queue, now: Date) -> Queue {
        var queue = queue
        queue.isActive = false
        if !queue.isMain { queue.lastStartedAt = max(queue.lastStartedAt ?? now, now) }
        return queue
    }

    /// `edited` as it should be saved. A new queue, or one whose schedule or stop time changed while inactive, counts
    /// every start up to `now` as handled: a daily 2:00 AM queue made at 3:00 PM waits for tomorrow instead of
    /// treating this morning's start as missed.
    public static func edited(_ edited: Queue, from original: Queue?, now: Date) -> Queue {
        var queue = edited
        let rescheduled = original.map { $0.schedule != edited.schedule || $0.stopTime != edited.stopTime } ?? true
        if rescheduled && !queue.isActive && !queue.isMain { queue.lastStartedAt = now }
        return queue
    }
}
