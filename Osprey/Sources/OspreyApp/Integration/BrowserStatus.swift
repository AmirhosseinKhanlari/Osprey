import Foundation
import SafariServices
import OspreyBridge
import OspreyIntegration

/// Where each supported browser stands, read from disk (Chromium browsers' native-messaging host
/// manifests) and from Safari (whether the user turned the extension on).
struct BrowserStatus: Identifiable, Equatable {
    enum State: Equatable {
        /// The browser's Application Support folder is missing.
        case notInstalled
        /// The host manifest exists and points at this copy of Osprey.
        case helperInstalled
        /// The host manifest is missing.
        case helperMissing
        /// The host manifest points at another copy of Osprey (or another program).
        case helperElsewhere
        case extensionOn
        case extensionOff
        /// Safari couldn't say (for example, when running outside an app bundle).
        case unknown

        var label: String {
            switch self {
            case .notInstalled: "Not installed"
            case .helperInstalled: "Helper installed"
            case .helperMissing: "Helper missing"
            case .helperElsewhere: "Helper points elsewhere"
            case .extensionOn: "Extension on"
            case .extensionOff: "Extension off"
            case .unknown: "Status unavailable"
            }
        }

        var isGood: Bool { self == .helperInstalled || self == .extensionOn }
        /// Something the user can fix (repair the helper, turn the extension on).
        var needsAttention: Bool { self == .helperMissing || self == .helperElsewhere || self == .extensionOff }
    }

    let name: String
    let state: State
    var id: String { name }

    /// Display names for `NativeHostInstaller.browserFolders`.
    private static let chromiumNames = [
        "Google/Chrome": "Google Chrome",
        "Microsoft Edge": "Microsoft Edge",
        "BraveSoftware/Brave-Browser": "Brave",
        "Chromium": "Chromium",
    ]

    /// Chrome-family browsers in the installer's order, each checked against this app's host executable.
    static func chromiumBrowsers(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 host: URL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/osprey-host"))
        -> [BrowserStatus] {
        NativeHostInstaller.browserFolders.map { folder in
            let support = home.appending(path: "Library/Application Support/\(folder)")
            let name = chromiumNames[folder] ?? folder
            guard FileManager.default.fileExists(atPath: support.path(percentEncoded: false)) else {
                return BrowserStatus(name: name, state: .notInstalled)
            }
            let manifest = support.appending(path: "NativeMessagingHosts/\(BridgeLocation.nativeHostName).json")
            guard let data = try? Data(contentsOf: manifest) else { return BrowserStatus(name: name, state: .helperMissing) }
            guard let path = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["path"] as? String else {
                return BrowserStatus(name: name, state: .helperElsewhere)
            }
            // Compare real paths: /tmp and /private/tmp (or a symlinked Applications folder) are the same place.
            let theirs = URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false)
            let ours = host.resolvingSymlinksInPath().path(percentEncoded: false)
            return BrowserStatus(name: name, state: theirs == ours ? .helperInstalled : .helperElsewhere)
        }
    }

    /// Asks Safari whether the Osprey extension is turned on. Safari sometimes can't answer right
    /// after the app launches (it is still registering the extension), so a failure is retried twice.
    static func safari() async -> BrowserStatus {
        for attempt in 0..<3 {
            do {
                let state = try await SFSafariExtensionManager.stateOfSafariExtension(
                    withIdentifier: BridgeLocation.safariExtensionIdentifier)
                return BrowserStatus(name: "Safari", state: state.isEnabled ? .extensionOn : .extensionOff)
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        return BrowserStatus(name: "Safari", state: .unknown)
    }
}
