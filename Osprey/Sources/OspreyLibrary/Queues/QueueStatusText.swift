import Foundation

/// A queue's status line in the sidebar: "Running · 2 of 3", "Starts 2:00 AM", "Waiting for Wi-Fi",
/// "On battery — waiting", "Stopped".
public enum QueueStatusText {
    public static let waitingForWiFi = "Waiting for Wi-Fi"
    public static let onBattery = "On battery — waiting"
    public static let stopped = "Stopped"

    /// - `running`: its downloads running now; `pending`: running plus queued.
    public static func line(_ decision: QueueDecision, isMain: Bool, running: Int, pending: Int, now: Date,
                            calendar: Calendar, locale: Locale = .current) -> String {
        switch decision {
        case .run:
            if pending == 0 { return isMain ? "Ready" : "Running" }
            return "Running · \(running) of \(pending)"
        case .wait(let start):
            return "Starts \(when(start, now: now, calendar: calendar, locale: locale))"
        case .hold(.wifi):
            return waitingForWiFi
        case .hold(.power):
            return onBattery
        case .stopped:
            return stopped
        }
    }

    /// "2:00 AM" today, "tomorrow 2:00 AM", "Tue 2:00 AM" within a week, else "Oct 20 at 2:00 AM".
    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0:
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return formatter.string(from: date)
        case 1:
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return "tomorrow \(formatter.string(from: date))"
        case 2...6:
            formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
            return formatter.string(from: date)
        default:
            formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
            return formatter.string(from: date)
        }
    }
}
