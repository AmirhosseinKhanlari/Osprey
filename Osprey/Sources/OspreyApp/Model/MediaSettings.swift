import Foundation
import Observation
import OspreyMedia

/// The video picker's remembered choices and default folders, kept in UserDefaults.
@MainActor @Observable
final class MediaSettings {
    private enum Key {
        static let videoFolder = "media.videoFolder"
        static let audioFolder = "media.audioFolder"
        static let compatible = "media.compatible"
        static let maxHeight = "media.maxHeight"
        static let subtitleLanguage = "media.subtitleLanguage"
        static let subtitleIsAuto = "media.subtitleIsAuto"
        /// Replaced by the menu's Auto-generated submenu (and `subtitleIsAuto`); removed on launch.
        static let legacyIncludeAutoCaptions = "media.includeAutoCaptions"
        static let audioLanguage = "media.audioLanguage"
        static let pickerMode = "media.pickerMode"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Where videos go; `~/Downloads/Video` by default.
    var videoFolder: URL { didSet { defaults.set(videoFolder.path(percentEncoded: false), forKey: Key.videoFolder) } }
    /// Where audio-only downloads go; `~/Downloads/Music` by default.
    var audioFolder: URL { didSet { defaults.set(audioFolder.path(percentEncoded: false), forKey: Key.audioFolder) } }
    /// Prefer H.264 + AAC in MP4, which QuickTime plays.
    var compatible: Bool { didSet { defaults.set(compatible, forKey: Key.compatible) } }
    /// The height the picker selects first (the highest one at or below it).
    var maxHeight: Int { didSet { defaults.set(maxHeight, forKey: Key.maxHeight) } }
    /// The last subtitle language chosen; nil when subtitles were off.
    var subtitleLanguage: String? { didSet { defaults.set(subtitleLanguage, forKey: Key.subtitleLanguage) } }
    /// The remembered subtitle is an automatic caption rather than an uploaded track.
    var subtitleIsAuto: Bool { didSet { defaults.set(subtitleIsAuto, forKey: Key.subtitleIsAuto) } }
    /// The audio track to download from a multi-language video: a language code ("en", "de-DE") or
    /// `FormatCatalog.originalAudioLanguage`. English until the user picks another language.
    var audioLanguage: String { didSet { defaults.set(audioLanguage, forKey: Key.audioLanguage) } }
    /// The single-video picker's last mode: the video qualities, or audio only. Video by default.
    var pickerMode: MediaPickerMode { didSet { defaults.set(pickerMode.rawValue, forKey: Key.pickerMode) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        videoFolder = Self.folder(defaults.string(forKey: Key.videoFolder)) ?? downloads.appending(path: "Video", directoryHint: .isDirectory)
        audioFolder = Self.folder(defaults.string(forKey: Key.audioFolder)) ?? downloads.appending(path: "Music", directoryHint: .isDirectory)
        compatible = defaults.object(forKey: Key.compatible) as? Bool ?? true
        let height = defaults.integer(forKey: Key.maxHeight)
        maxHeight = height > 0 ? height : 1080
        subtitleLanguage = defaults.string(forKey: Key.subtitleLanguage)
        subtitleIsAuto = defaults.bool(forKey: Key.subtitleIsAuto)
        defaults.removeObject(forKey: Key.legacyIncludeAutoCaptions)
        audioLanguage = defaults.string(forKey: Key.audioLanguage).flatMap { $0.isEmpty ? nil : $0 } ?? FormatCatalog.defaultAudioLanguage
        pickerMode = defaults.string(forKey: Key.pickerMode).flatMap(MediaPickerMode.init(rawValue:)) ?? .video
    }

    private static func folder(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// What the single-video picker lists: the video qualities, or the audio-only formats (M4A, MP3).
enum MediaPickerMode: String, Hashable {
    case video, audio

    var title: String { self == .video ? "Video" : "Audio only" }
}
