import Foundation

enum Category: String, CaseIterable, Identifiable, Hashable {
    case video = "Video", applications = "Applications", archives = "Archives"
    case documents = "Documents", music = "Music", other = "Other"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .video: "video"
        case .applications: "square.grid.2x2"
        case .archives: "archivebox"
        case .documents: "doc.text"
        case .music: "music.note"
        case .other: "tray"
        }
    }

    static func infer(fromFileName name: String) -> Category {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "webm", "avi", "m4v", "ts": return .video
        case "dmg", "pkg", "app", "xip", "exe", "msi": return .applications
        case "zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "iso", "tar": return .archives
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "epub", "csv", "parquet": return .documents
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": return .music
        default: return .other
        }
    }
}
