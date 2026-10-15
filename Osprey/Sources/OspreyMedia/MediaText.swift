import Foundation

/// Text and number helpers for values that come from a site (through yt-dlp), so none of them can trap.
public enum MediaText {
    /// A running time as a clock: "9:56", "1:02:03". Nil for a negative, non-finite or absurd (over 10,000 hours) value.
    public static func clock(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 36_000_000, let total = Int(exactly: seconds.rounded()) else { return nil }
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `value` as a byte count: nil unless it is finite, not negative and fits in an Int64.
    static func byteCount(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0, value < 9.0e18 else { return nil }
        return Int64(exactly: value.rounded())
    }

    /// `a + b`, or nil when it would overflow.
    static func sum(_ a: Int64, _ b: Int64) -> Int64? {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : result
    }

    /// `a + b`, clamped to Int64's range.
    static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }
}
