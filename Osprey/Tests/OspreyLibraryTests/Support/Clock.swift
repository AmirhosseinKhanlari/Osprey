import Foundation

/// New York: DST begins 2026-03-08 (2:00 AM → 3:00 AM) and ends 2026-11-01 (2:00 AM → 1:00 AM).
let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

/// A wall-clock time in New York.
func ny(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// An absolute instant, written in UTC: `utc("2026-03-08T07:00:00Z")`.
func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

/// Minutes since midnight.
func hm(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

let everyDay: Set<Int> = Set(1...7)
let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]
