import Foundation

/// RFC 6266 / 5987 filename extraction. `filename*` beats `filename`.
public enum ContentDisposition {
    public static func filename(from header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        for rawPart in header.split(separator: ";") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = part.dropFirst("filename*=".count)
                if let marker = value.range(of: "''") {
                    let encoded = value[marker.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return sanitize(decoded) }
                }
            } else if lower.hasPrefix("filename=") {
                var value = String(part.dropFirst("filename=".count))
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                plain = value
            }
        }
        guard let plain, !plain.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return sanitize(plain)
    }

    /// APFS allows 255 UTF-8 bytes per name; reserve room for ".slpart.json" (12) and a " 99" counter (3).
    public static let maxNameBytes = 240
    private static let maxExtensionBytes = 16

    /// Last path component only, no ':' (Finder separator), no leading dot, max `maxNameBytes` UTF-8 bytes.
    public static func sanitize(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
        var cleaned = last.replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix(".") { cleaned = "_" + cleaned.dropFirst() }
        if cleaned.isEmpty { return "download" }
        return truncate(cleaned, toBytes: maxNameBytes)
    }

    /// Truncates on Character boundaries, preserving a short extension when present.
    private static func truncate(_ name: String, toBytes limit: Int) -> String {
        if name.utf8.count <= limit { return name }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = String(name[dot...])   // includes the dot
            if ext.utf8.count > 1, ext.utf8.count <= maxExtensionBytes + 1 {
                let base = prefix(String(name[..<dot]), bytes: limit - ext.utf8.count)
                if !base.isEmpty { return base + ext }
            }
        }
        return prefix(name, bytes: limit)
    }

    private static func prefix(_ s: String, bytes limit: Int) -> String {
        var result = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            result.append(ch)
            used += n
        }
        return result
    }
}
