import Foundation

/// A named download queue, saved in `queues.json`. Main always exists, runs at once and can't be scheduled; the others
/// start by hand, once at a date and time, or daily on chosen weekdays.
public struct Queue: Codable, Sendable, Equatable, Identifiable {
    public enum Schedule: Codable, Sendable, Equatable {
        case manual
        case once(start: Date)
        /// `time`: minutes since midnight. `weekdays`: `Calendar` weekday numbers, 1 = Sunday … 7 = Saturday.
        case daily(time: Int, weekdays: Set<Int>)
    }

    public enum AfterFinish: String, Codable, Sendable, CaseIterable {
        case nothing, notify, quit, sleep, shutdown
    }

    /// Main's fixed id. A saved download without a queue belongs to it.
    public static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// The ready-made Later queue's id ("Download later" picks it by default while it exists).
    public static let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    /// "Files at once".
    public static let concurrencyRange = 1...8

    public var id: UUID
    public var name: String
    public var isMain: Bool
    /// How many of its downloads run at once; `slots` is the value clamped to `concurrencyRange`.
    public var maxConcurrent: Int
    public var schedule: Schedule
    /// Minutes since midnight. The first such time after the queue started stops it.
    public var stopTime: Int?
    /// Holds while the network is expensive (a phone hotspot) or constrained (Low Data Mode).
    public var onlyOnWiFi: Bool
    /// Holds while the Mac runs on battery.
    public var onlyOnAC: Bool
    /// Prevents system sleep while it runs, and idle sleep before a start due within 12 h on AC power.
    public var keepAwake: Bool
    public var afterFinish: AfterFinish
    /// Started by the user or by its schedule, and not yet finished or stopped.
    public var isActive: Bool
    /// The start this activation began with (a scheduled start instant, or when the user started it). A start at or
    /// before it has been handled; a later one that was missed still counts inside its window.
    public var lastStartedAt: Date?

    public init(id: UUID = UUID(), name: String, isMain: Bool = false, maxConcurrent: Int = 2, schedule: Schedule = .manual,
                stopTime: Int? = nil, onlyOnWiFi: Bool = false, onlyOnAC: Bool = false, keepAwake: Bool = false,
                afterFinish: AfterFinish = .nothing, isActive: Bool = false, lastStartedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.maxConcurrent = maxConcurrent
        self.schedule = schedule
        self.stopTime = stopTime
        self.onlyOnWiFi = onlyOnWiFi
        self.onlyOnAC = onlyOnAC
        self.keepAwake = keepAwake
        self.afterFinish = afterFinish
        self.isActive = isActive
        self.lastStartedAt = lastStartedAt
    }

    /// Main: runs at once, four files at a time.
    public static var main: Queue { Queue(id: mainID, name: "Main", isMain: true, maxConcurrent: 4) }

    /// The ready-made Later queue: started by hand, two files at a time.
    public static var later: Queue { Queue(id: laterID, name: "Later") }

    public var slots: Int { min(max(maxConcurrent, Self.concurrencyRange.lowerBound), Self.concurrencyRange.upperBound) }
}
