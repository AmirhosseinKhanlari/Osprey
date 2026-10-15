import Foundation
import OspreyEngine

/// What a media download needs to rebuild itself after a relaunch. The app's saved list (`DownloadRecord` in
/// OspreyLibrary) carries one for every video; it lives here because `MediaDownload(resuming:)` reads it.
public struct MediaRecord: Codable, Sendable, Equatable {
    /// Where the download stood: still fetching parts, or every part on disk and only the merge left.
    public enum Phase: String, Codable, Sendable, Equatable {
        case downloading, readyToMerge
    }

    /// The parts of `MediaInfo` a download uses (its file name comes from `title` and `id`), plus what the list shows.
    public struct Video: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var uploader: String?
        public var duration: Double?
        public var thumbnail: URL?
        public var webpageURL: URL?

        public init(id: String, title: String, uploader: String? = nil, duration: Double? = nil, thumbnail: URL? = nil,
                    webpageURL: URL? = nil) {
            self.id = id
            self.title = title
            self.uploader = uploader
            self.duration = duration
            self.thumbnail = thumbnail
            self.webpageURL = webpageURL
        }

        public init(_ info: MediaInfo) {
            self.init(id: info.id, title: info.title, uploader: info.uploader, duration: info.duration,
                      thumbnail: info.thumbnail, webpageURL: info.webpageURL)
        }

        /// A `MediaInfo` with these details and no formats: enough for `MediaDownload`, which takes its formats from
        /// the plan.
        public var mediaInfo: MediaInfo {
            MediaInfo(id: id, title: title, uploader: uploader, duration: duration, thumbnail: thumbnail,
                      webpageURL: webpageURL)
        }
    }

    public var video: Video
    public var plan: MediaPlan
    /// The folder the final file goes to.
    public var folder: URL
    /// The `<uuid>` of `<folder>/.osprey-media-<uuid>/`, where the parts are.
    public var hiddenFolderID: UUID
    public var phase: Phase
    public var warning: MediaWarning?

    /// The plan's formats keep no `Cookie` or `Authorization` header: the saved list never holds credentials.
    public init(video: Video, plan: MediaPlan, folder: URL, hiddenFolderID: UUID, phase: Phase, warning: MediaWarning?) {
        var plan = plan
        for index in plan.parts.indices {
            plan.parts[index].format.httpHeaders = HTTPHeaders.withoutSensitive(plan.parts[index].format.httpHeaders)
        }
        self.video = video
        self.plan = plan
        self.folder = folder
        self.hiddenFolderID = hiddenFolderID
        self.phase = phase
        self.warning = warning
    }
}

extension MediaRecord.Phase {
    /// `readyToMerge` once every part is on disk (merging, or a merge that was stopped or failed); else `downloading`.
    public init(_ snapshot: MediaSnapshot) {
        let partsDone = !snapshot.parts.isEmpty && snapshot.parts.allSatisfy { $0.state == .completed }
        self = snapshot.phase == .merging || partsDone ? .readyToMerge : .downloading
    }
}

extension MediaInfo {
    /// A video known by its details only (a restored download): no formats, subtitles or captions.
    init(id: String, title: String, uploader: String?, duration: Double?, thumbnail: URL?, webpageURL: URL?) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnail = thumbnail
        self.webpageURL = webpageURL
        formats = []
        subtitles = [:]
        automaticCaptions = [:]
        protectedFormatCount = 0
        droppedFormatCount = 0
    }
}
