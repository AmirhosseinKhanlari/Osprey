import Foundation
import OspreyBridge
import OspreyIntegration

/// Runs the bridge socket for the browser extensions while the app is open.
@MainActor
final class CaptureService {
    private let manager: DownloadManager
    private let store: IntegrationSettingsStore
    private let panels: CaptureProgressPanels
    private let media: MediaCoordinator
    private var server: BridgeServer?

    init(manager: DownloadManager, store: IntegrationSettingsStore, panels: CaptureProgressPanels, media: MediaCoordinator) {
        self.manager = manager
        self.store = store
        self.panels = panels
        self.media = media
    }

    func start() {
        guard server == nil else { return }
        Self.installChromeHostManifests()
        CaptureNotifier.requestAuthorization()
        let store = self.store
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let media = self.media
        // The browser waits for this reply, so only schedule the picker and answer at once; the user's choice
        // in the picker is never awaited here.
        let router = CaptureRouter(appVersion: version, settings: { store.settings }, acceptMedia: { order in
            Task { @MainActor in media.open(order) }
            return true
        }) { [weak self] order, gate in
            await MainActor.run { self?.accept(order, gate: gate) ?? false }
        }
        let server = BridgeServer(socketURL: BridgeLocation.defaultSocketURL(), verifier: Self.verifier()) { request, gate in
            await router.handle(request, gate: gate)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Osprey: browser bridge failed to start: \(error)")
        }
    }

    /// Adds the capture, then tells the user: a progress window, or a notification when that's turned off.
    /// Nothing is added once the request has timed out: the browser was told no and is keeping the file.
    private func accept(_ order: CaptureOrder, gate: CommitGate) -> Bool {
        guard gate.tryCommit() else { return false }
        let item = manager.addCaptured(order)
        let showWindow = store.settings.showProgressWindow
        let panels = self.panels
        // The reply waits for this method, so the window (its first layout is the slow part) comes a turn later.
        DispatchQueue.main.async {
            if showWindow {
                panels.show(item)
            } else {
                CaptureNotifier.notifyCaptured(fileName: order.preferredFilename ?? order.url.lastPathComponent,
                                               isPrivate: order.isPrivate)
            }
        }
        return true
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// Writes the Chrome host manifests when running from an .app bundle that contains the host.
    /// Also used by the Settings "Repair Chrome helper" button.
    nonisolated static func installChromeHostManifests() {
        let host = Bundle.main.bundleURL.appending(path: "Contents/MacOS/osprey-host")
        guard FileManager.default.isExecutableFile(atPath: host.path(percentEncoded: false)) else { return }
        do {
            try NativeHostInstaller().install(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])
        } catch let error as NativeHostInstallError {
            // Other browsers were still written; report each failed folder.
            for failure in error.failures {
                NSLog("Osprey: could not install the Chrome helper manifest in \(failure.folder): \(failure.message)")
            }
        } catch {
            NSLog("Osprey: could not install the Chrome helper manifest: \(error)")
        }
    }

    private static func verifier() -> any PeerVerifier {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OSPREY_BRIDGE_INSECURE"] == "1" { return AllowAllPeerVerifier() }
        #endif
        return CodeSignaturePeerVerifier(teamID: BridgeLocation.teamID,
                                         identifiers: [BridgeLocation.hostIdentifier, BridgeLocation.safariExtensionIdentifier])
    }
}
