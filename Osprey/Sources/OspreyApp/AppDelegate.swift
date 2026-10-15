import AppKit
import OspreyIntegration
import OspreyMedia

/// Owns what lives as long as the app rather than a window: the downloads, the capture pop-ups and the
/// browser bridge. A capture can launch Osprey in the background, and closing the main window must
/// not stop the bridge, so none of this hangs off the window's lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: DownloadManager
    let panels: CaptureProgressPanels
    let media: MediaCoordinator
    /// yt-dlp and ffmpeg for Settings › Media; kept here so an install keeps reporting while Settings is closed.
    let toolStatus: ToolStatus
    private var capture: CaptureService?
    /// Leftovers older than this launch belong to earlier runs (or a crash) and are swept.
    private let launchedAt = Date()
    /// This copy's run lock: another copy (a Debug build next to the installed one) then never sweeps our live files.
    private var runLock: MediaCleanup.RunLock?
    /// Set once a quit has begun; a second request is cancelled, and the first one finishes the quit.
    private var quitting = false

    override init() {
        _ = LegacyDataImport.once   // before MediaSettings and the stores below read the defaults
        let manager = DownloadManager()
        self.manager = manager
        panels = CaptureProgressPanels(manager: manager)
        media = MediaCoordinator(manager: manager, settings: MediaSettings())
        toolStatus = ToolStatus(tools: manager.mediaTools)
        super.init()
        media.showMainWindow = { [weak self] in self?.showMainWindow() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The saved list comes back before the main window shows and before the media sweep (didFinishLaunching).
        manager.restore()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.startPolling()
        startCapture()
        // Once per launch: refresh the managed yt-dlp if a day has passed. Failures wait for the next launch.
        let tools = manager.mediaTools
        Task.detached(priority: .background) { await ToolInstaller(tools: tools).updateIfDue() }
        sweepMediaLeftovers()
        // A bare `swift run` executable isn't activated by macOS, so bring it forward ourselves. A real .app
        // is activated by Launch Services when the user opens it, and must stay behind the browser when a
        // capture launched it (NSWorkspace with activates = false).
        if Bundle.main.bundleURL.pathExtension != "app" { NSApp.activate() }
    }

    /// Starts the bridge and installs the Chrome helper manifests. A no-op while running; after a failed
    /// start, the next call (the main window calls it whenever it opens) tries again.
    func startCapture() {
        let service = capture ?? CaptureService(manager: manager, store: IntegrationSettingsStore(), panels: panels, media: media)
        capture = service
        service.start()
    }

    /// Opens the main window if it's closed, or brings it forward. An open window is only ordered front: asking
    /// SwiftUI to open it again dismisses a sheet it is showing (say, the Safari setup the picker waits behind).
    func showMainWindow() {
        let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        if NSApp.isHidden, let main {
            NSApp.unhide(nil)                  // a hidden app's window isn't "visible", but it is open
            main.makeKeyAndOrderFront(nil)
        } else if let main, main.isVisible || main.isMiniaturized {
            main.makeKeyAndOrderFront(nil)
        } else if let open = panels.openMainWindow {
            open()
        } else {
            main?.makeKeyAndOrderFront(nil)
        }
    }

    /// Deletes cookie folders, hidden part folders and marked `*.osprey-partial.*` merges that earlier runs left behind,
    /// looking only in the media folders (videos, audio) and their playlist subfolders. Skipped while another copy of
    /// Osprey runs, since those files may be its live ones. On the first launch that can, it also sweeps the former
    /// app's leftovers the same way. Runs off the main thread.
    private func sweepMediaLeftovers() {
        runLock = MediaCleanup.RunLock.acquire()
        guard runLock != nil else { return }
        let folders = [media.settings.videoFolder, media.settings.audioFolder]
        let cutoff = launchedAt
        let restored = manager.restoredHiddenFolderIDs
        let legacyPending = !UserDefaults.standard.bool(forKey: Self.legacyLeftoversSweptKey)
        let legacyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyLeftovers.legacyAppBundleID).isEmpty
        Task.detached(priority: .utility) {
            guard !MediaCleanup.RunLock.otherCopiesRunning() else { return }
            // A restored video's hidden part folder holds what it resumes from: never swept.
            let removed = MediaCleanup.sweepLeftovers(in: folders, olderThan: cutoff, keeping: restored)
            if !removed.isEmpty { NSLog("Osprey: removed %d media leftovers from earlier runs", removed.count) }
            // Once: the same sweep for the former app's leftovers, retried on a later launch while that app runs.
            if legacyPending, let legacy = LegacyLeftovers.sweep(in: folders, olderThan: cutoff, legacyAppRunning: legacyRunning) {
                UserDefaults.standard.set(true, forKey: AppDelegate.legacyLeftoversSweptKey)
                if !legacy.isEmpty { NSLog("Osprey: removed %d leftovers of the former app", legacy.count) }
            }
        }
    }

    /// Set once the former app's leftovers have been swept (see `LegacyLeftovers`).
    nonisolated static let legacyLeftoversSweptKey = "legacyLeftoversSwept"

    /// Quitting waits (at most 3 s) while every download pauses (an HTTP job saves its segment map, yt-dlp gets SIGINT, a
    /// merge stops and is saved ready to merge), private downloads are discarded, and the list is flushed. A second
    /// request meanwhile is cancelled: AppKit allows one pending `.terminateLater`, and the first reply quits anyway.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateCancel }
        quitting = true
        Task { [self] in
            await manager.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // applicationShouldTerminate already paused everything; this only catches stragglers: yt-dlp and ffmpeg each
        // lead their own process group and would outlive the app, and a cookie file may still be on disk. Synchronous.
        MediaCleanup.terminateAll()
        runLock?.release()
        capture?.stop()   // closes the socket and removes the socket file
    }
}
