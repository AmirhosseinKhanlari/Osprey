import Foundation

/// What the app needs from any kind of download (a plain HTTP job, or a media job that muxes streams).
public protocol DownloadTask: Actor {
    nonisolated var id: UUID { get }
    func start() async
    func pause() async
    func setSpeedLimit(_ bytesPerSecond: Double?)
    func snapshot() -> DownloadSnapshot
    /// Stops the task and deletes its partial data.
    func discard() async
    /// Stops the task because the app is quitting, leaving what is on disk resumable. The default is `pause()` (an HTTP
    /// job saves its segment map; yt-dlp gets SIGINT and keeps its `.part` files); a media download also stops a merge.
    func suspendForQuit() async
}

extension DownloadTask {
    public func suspendForQuit() async { await pause() }
}

extension DownloadJob: DownloadTask {}
