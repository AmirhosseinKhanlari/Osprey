import AppKit

public enum AppLauncher {
    /// Starts Osprey in the background. Returns false when it is not installed.
    @discardableResult
    public static func launchOsprey() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BridgeLocation.appBundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }
}
