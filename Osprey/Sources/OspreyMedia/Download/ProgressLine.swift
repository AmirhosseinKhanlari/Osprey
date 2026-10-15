import Foundation

/// One `SLIPPROG` line printed by yt-dlp's `--progress-template`.
/// `SLIPPROG <downloaded> <total|NA> <total_estimate|NA> <speed|NA> <eta|NA> <frag_index|NA> <frag_count|NA>`
public struct ProgressLine: Sendable, Equatable {
    public var downloaded: Int64
    /// `total_bytes`, or else `total_bytes_estimate`.
    public var total: Int64?
    public var speed: Double?
    public var fragment: (Int, Int)?

    public static func == (a: ProgressLine, b: ProgressLine) -> Bool {
        a.downloaded == b.downloaded && a.total == b.total && a.speed == b.speed
            && a.fragment?.0 == b.fragment?.0 && a.fragment?.1 == b.fragment?.1
    }

    public static func parse(_ line: String) -> ProgressLine? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 8, parts[0] == "SLIPPROG" else { return nil }
        guard let downloaded = bytes(parts[1]) else { return nil }
        let total = bytes(parts[2]) ?? bytes(parts[3])
        var speed: Double?
        if let s = Double(parts[4]), s.isFinite, s >= 0 { speed = s }
        var fragment: (Int, Int)?
        if let i = Int(parts[6]), let n = Int(parts[7]), i >= 0, n > 0 { fragment = (i, n) }
        return ProgressLine(downloaded: downloaded, total: total, speed: speed, fragment: fragment)
    }

    /// Accepts integers and floats ("1234.5" estimates); `NA`/`None`/garbage give nil.
    private static func bytes(_ token: String) -> Int64? {
        guard let d = Double(token), d.isFinite, d >= 0, d < 9e18 else { return nil }
        return Int64(d)
    }
}
