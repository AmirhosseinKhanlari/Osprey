import Foundation
import OspreyEngine
@testable import OspreyLibrary
@testable import OspreyMedia

let sampleAddedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A file download as the list saves it: 1 000 of 4 000 bytes, captured from a browser link menu.
func fileRecord(id: UUID = UUID(), state: DownloadRecord.State = .paused,
                destination: URL = URL(fileURLWithPath: "/tmp/osprey-tests/Archives/file.zip"),
                addedAt: Date = sampleAddedAt, hasStoredCredentials: Bool = false,
                headers: [String: String] = ["User-Agent": "UA", "Referer": "https://files.example/"]) -> DownloadRecord {
    DownloadRecord(id: id, kind: .file, url: URL(string: "https://files.example/file.zip")!, category: "Archives",
                   origin: .browser(fromMenu: true), maxConnections: 8, playlistTitle: nil, addedAt: addedAt,
                   completedAt: state == .completed ? addedAt.addingTimeInterval(60) : nil, state: state,
                   destination: destination, downloaded: 1_000, totalSize: 4_000, activeSeconds: 12.5,
                   hasStoredCredentials: hasStoredCredentials, media: nil, preferredFilename: "file.zip", headers: headers)
}

func mediaFormat(_ id: String, ext: String, url: String?, proto: String = "https") -> MediaFormat {
    var object: [String: Any] = ["format_id": id, "ext": ext, "protocol": proto, "http_headers": ["User-Agent": "UA"]]
    if let url { object["url"] = url }
    return try! JSONDecoder().decode(MediaFormat.self, from: JSONSerialization.data(withJSONObject: object))
}

func twoPartPlan() -> MediaPlan {
    MediaPlan(parts: [MediaPart(format: mediaFormat("136", ext: "mp4", url: "https://media.example/136"), role: .video),
                      MediaPart(format: mediaFormat("140", ext: "m4a", url: nil, proto: "m3u8_native"), role: .audio)],
              container: .mp4, convertToMP3: false, subtitle: nil, subtitleLanguage: nil)
}

func mediaRecord(folder: URL, hiddenFolderID: UUID, phase: MediaRecord.Phase = .downloading) -> MediaRecord {
    MediaRecord(video: MediaRecord.Video(id: "abc123", title: "Demo Talk"), plan: twoPartPlan(), folder: folder,
                hiddenFolderID: hiddenFolderID, phase: phase, warning: nil)
}

/// A video from a playlist; its hidden folder is named after its id, as `MediaDownload` names it.
func mediaDownloadRecord(id: UUID = UUID(), state: DownloadRecord.State = .paused, phase: MediaRecord.Phase = .downloading,
                         addedAt: Date = sampleAddedAt,
                         folder: URL = URL(fileURLWithPath: "/tmp/osprey-tests/Video")) -> DownloadRecord {
    DownloadRecord(id: id, kind: .media, url: URL(string: "https://www.youtube.com/watch?v=abc123")!, category: "Video",
                   origin: .addURL, maxConnections: 16, playlistTitle: "Course", addedAt: addedAt, completedAt: nil,
                   state: state, destination: folder.appending(path: "Demo Talk.mp4"), downloaded: 500, totalSize: nil,
                   activeSeconds: 3, hasStoredCredentials: false,
                   media: mediaRecord(folder: folder, hiddenFolderID: id, phase: phase), preferredFilename: nil, headers: [:])
}
