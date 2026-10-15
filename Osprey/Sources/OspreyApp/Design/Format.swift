import Foundation
import OspreyMedia

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "—" }
        let clamped = Int64(min(bytesPerSecond, Double(Int64.max / 2)))
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .file) + "/s"
    }

    /// A speed split for large display: the number ("42.6") and its unit ("MB/s").
    static func speedParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        guard bytesPerSecond >= 1 else { return ("0", "MB/s") }   // idle reads "0 MB/s", not "Zero bytes/s"
        let clamped = bytesPerSecond.isFinite ? Int64(min(max(bytesPerSecond, 0), Double(Int64.max / 2))) : 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false   // "0" rather than "Zero"
        formatter.includesUnit = false
        let value = formatter.string(fromByteCount: clamped)
        formatter.includesUnit = true
        formatter.includesCount = false
        return (value, formatter.string(fromByteCount: clamped) + "/s")
    }

    /// Time left, e.g. "4 min" or with `units: 2` "1 min, 12 sec"; "—" when unknown.
    static func eta(remaining: Int64, speed: Double, units: Int = 1) -> String {
        guard speed.isFinite, speed > 1, remaining > 0 else { return "—" }
        let seconds = Double(remaining) / speed
        guard seconds.isFinite else { return "—" }
        return duration(seconds, units: units)
    }

    static func duration(_ seconds: Double, units: Int = 1) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = units
        return formatter.string(from: max(seconds, 1)) ?? "—"
    }

    /// A running time as a clock: "9:56", "1:02:03". Nil for a duration no clock can show (it comes from the site).
    static func clock(_ seconds: Double) -> String? { MediaText.clock(seconds) }

    /// A folder with the home directory shortened to "~".
    static func path(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        guard path.hasPrefix(home) else { return path }
        let rest = path.dropFirst(home.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rest.isEmpty ? "~" : "~/" + rest
    }

    /// The last two folders of a path as breadcrumbs, e.g. "Downloads › Applications".
    static func crumbs(_ folder: URL) -> String {
        let parts = folder.pathComponents.filter { $0 != "/" }.suffix(2)
        return parts.joined(separator: " › ")
    }

    static func ago(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return now.timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
    }
}
