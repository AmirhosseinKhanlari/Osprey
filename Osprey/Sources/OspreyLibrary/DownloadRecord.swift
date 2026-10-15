import Foundation
import OspreyEngine
import OspreyMedia

/// One download in the saved list (`library.json`).
public struct DownloadRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, media }

    /// How the download reached Osprey (the app's `DownloadOrigin`).
    public enum Origin: Codable, Sendable, Equatable {
        case addURL
        case browser(fromMenu: Bool)
    }

    /// A running download is saved as `paused`: it comes back paused.
    public enum State: Codable, Sendable, Equatable {
        case paused, completed
        case failed(String)
    }

    public var id: UUID
    public var kind: Kind
    /// For a file the download URL; for media the page URL.
    public var url: URL
    /// The app's `Category` raw value ("Video", "Archives", …).
    public var category: String
    public var origin: Origin
    public var maxConnections: Int
    public var playlistTitle: String?
    public var addedAt: Date
    public var completedAt: Date?
    public var state: State
    /// The final file, or, while unfinished, the folder plus the chosen name.
    public var destination: URL
    /// Shown until the restored task reports its own progress.
    public var downloaded: Int64
    public var totalSize: Int64?
    public var activeSeconds: Double
    /// Its `Cookie` / `Authorization` headers are in the Keychain (`CredentialVault`) under `id`.
    public var hasStoredCredentials: Bool
    /// Required when `kind == .media`.
    public var media: MediaRecord?
    /// The browser's suggested file name, so a download that starts over keeps it.
    public var preferredFilename: String?
    /// The request's other headers (User-Agent, Referer…), so a download that starts over sends them again.
    public var headers: [String: String]

    public init(id: UUID, kind: Kind, url: URL, category: String, origin: Origin, maxConnections: Int, playlistTitle: String?,
                addedAt: Date, completedAt: Date?, state: State, destination: URL, downloaded: Int64, totalSize: Int64?,
                activeSeconds: Double, hasStoredCredentials: Bool, media: MediaRecord?, preferredFilename: String?,
                headers: [String: String]) {
        self.id = id
        self.kind = kind
        self.url = url
        self.category = category
        self.origin = origin
        self.maxConnections = maxConnections
        self.playlistTitle = playlistTitle
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.state = state
        self.destination = destination
        self.downloaded = downloaded
        self.totalSize = totalSize
        self.activeSeconds = activeSeconds
        self.hasStoredCredentials = hasStoredCredentials
        self.media = media
        self.preferredFilename = preferredFilename
        self.headers = HTTPHeaders.withoutSensitive(headers)       // credentials live only in the Keychain
    }

    /// True until it completes or fails.
    public var isUnfinished: Bool { state == .paused }

    /// The state a download is saved with: running, queued and paused all come back paused.
    public static func state(for state: DownloadState) -> State {
        switch state {
        case .completed: .completed
        case .failed(let message): .failed(message)
        case .idle, .probing, .downloading, .finishing, .paused: .paused
        }
    }
}
