import Foundation

/// Shortens a label to a width before it reaches the UI, so a control sized from its content (an AppKit pop-up
/// button) shows "Chinese, Tr…" rather than collapsing its text to "…".
public enum TextFit {
    /// `text` when it fits `maxWidth` (or there's no limit); otherwise the longest prefix, without trailing spaces or
    /// punctuation, followed by "…" that fits. At least one character is kept.
    public static func truncate(_ text: String, maxWidth: Double?, measure: (String) -> Double) -> String {
        guard let maxWidth, measure(text) > maxWidth, text.count > 1 else { return text }
        let characters = Array(text)
        let trim = CharacterSet.whitespaces.union(.punctuationCharacters)
        for length in stride(from: characters.count - 1, through: 1, by: -1) {
            let head = String(characters[0..<length]).trimmingCharacters(in: trim)
            guard !head.isEmpty else { continue }
            let candidate = head + "…"
            if measure(candidate) <= maxWidth { return candidate }
        }
        return String(characters[0]) + "…"
    }
}
