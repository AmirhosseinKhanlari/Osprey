import Foundation

public struct DownloadOptions: Sendable {
    public var maxConnections = 8
    public var minPiece: Int64 = 11_680
    public var fastMinPiece: Int64 = 116_800
    public var fastSpeedThreshold: Double = 116_800      // bytes/s
    public var stallInterval: TimeInterval = 1
    public var phaseTimeout: TimeInterval = 30
    public var giveUpWithoutData: TimeInterval = 300
    public var speedLimit: Double?                       // bytes/s
    public var retry = RetryPolicy()
    public var headers: [String: String] = [:]
    /// Name chosen by the browser (it already applied Content-Disposition); sanitised before use.
    public var preferredFilename: String?
    /// Captured from a private window: the resume sidecar keeps no Referer (the page the user was on).
    public var isPrivate = false

    /// Supplies a fresh request when the download's URL expires (a media URL is refreshed by re-running
    /// yt-dlp). When nil, the original URL is probed again. Its headers are subject to credential scoping.
    public var urlResolver: (@Sendable () async throws -> URLRequest)?

    /// How long a refresh waits for `urlResolver` before treating it as failed.
    public var resolverTimeout: TimeInterval = 60

    public init() {}
}
