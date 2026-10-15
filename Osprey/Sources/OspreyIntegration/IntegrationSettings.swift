import Foundation
import OspreyBridge

public struct IntegrationSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var extensions: [String]
    public var captureInPrivate: Bool
    /// Show the floating progress window for each browser capture (otherwise post a notification).
    public var showProgressWindow: Bool
    /// Show the floating video button in browsers.
    public var videoButton: Bool

    public init(enabled: Bool, extensions: [String], captureInPrivate: Bool, showProgressWindow: Bool = true,
                videoButton: Bool = true) {
        self.videoButton = videoButton
        self.enabled = enabled
        self.extensions = extensions
        self.captureInPrivate = captureInPrivate
        self.showProgressWindow = showProgressWindow
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, extensions, captureInPrivate, showProgressWindow, videoButton
    }

    /// Missing keys take their defaults, so JSON saved by an older version still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? fallback.extensions
        captureInPrivate = try container.decodeIfPresent(Bool.self, forKey: .captureInPrivate) ?? fallback.captureInPrivate
        showProgressWindow = try container.decodeIfPresent(Bool.self, forKey: .showProgressWindow) ?? fallback.showProgressWindow
        videoButton = try container.decodeIfPresent(Bool.self, forKey: .videoButton) ?? fallback.videoButton
    }

    /// Common archive, installer, media and document types, plus dmg/pkg/xip for macOS. `*` matches any suffix (`r0*` → r00, r01…).
    public static let defaultExtensions = [
        "3gp", "7z", "aac", "ace", "aif", "apk", "arj", "asf", "avi", "bin", "bz2", "dmg", "exe", "gz", "gzip",
        "img", "iso", "lzh", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "mpa", "mpe", "mpeg", "mpg", "msi", "msu",
        "ogg", "ogv", "pdf", "pkg", "plj", "pps", "ppt", "qt", "r0*", "r1*", "ra", "rar", "rm", "rmvb", "sea",
        "sit", "sitx", "tar", "tif", "tiff", "wav", "webm", "wma", "wmv", "xip", "xz", "z", "zip",
    ]

    public static let `default` = IntegrationSettings(enabled: true, extensions: defaultExtensions, captureInPrivate: false,
                                                       showProgressWindow: true)

    /// Parses the Settings "File types" text: lowercased, split on whitespace/commas/semicolons,
    /// surrounding dots stripped, empties dropped, duplicates removed (first occurrence wins).
    public static func parseExtensions(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.lowercased().components(separatedBy: separators) {
            let ext = piece.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !ext.isEmpty, seen.insert(ext).inserted { result.append(ext) }
        }
        return result
    }

    public var rules: CaptureRules {
        CaptureRules(enabled: enabled, extensions: extensions, captureInPrivate: captureInPrivate, videoButton: videoButton)
    }
}

/// Persists the integration settings as JSON in UserDefaults.
public final class IntegrationSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "integrationSettings"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: IntegrationSettings {
        get {
            lock.withLock {
                guard let data = defaults.data(forKey: key),
                      let decoded = try? JSONDecoder().decode(IntegrationSettings.self, from: data) else { return .default }
                return decoded
            }
        }
        set {
            lock.withLock {
                if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
            }
        }
    }
}
