import Foundation

public enum BridgeLocation {
    public static let teamID = "8CG9QYMSR5"
    public static let appGroup = "8CG9QYMSR5.com.akhanlari.osprey"
    public static let appBundleID = "com.akhanlari.osprey"
    public static let hostIdentifier = "com.akhanlari.osprey.host"
    public static let safariExtensionIdentifier = "com.akhanlari.osprey.SafariExtension"
    public static let nativeHostName = "com.akhanlari.osprey.host"
    public static let chromeExtensionID = "hdaelhdfolkmnghifnpopgadkndofanj"
    public static let chromeExtensionOrigin = "chrome-extension://hdaelhdfolkmnghifnpopgadkndofanj/"
    #if DEBUG
    /// Overrides the socket path, for unsigned SwiftPM development runs. Debug builds only: in a release
    /// build any process of the user could set it (`launchctl setenv`) and receive captures, cookies included.
    public static let socketOverrideVariable = "OSPREY_BRIDGE_SOCKET"
    #endif

    public static func defaultSocketURL() -> URL {
        #if DEBUG
        return defaultSocketURL(environment: ProcessInfo.processInfo.environment, allowsOverride: true)
        #else
        return groupSocketURL()   // release builds never read the override
        #endif
    }

    #if DEBUG
    static func defaultSocketURL(environment: [String: String], allowsOverride: Bool) -> URL {
        if allowsOverride, let override = environment[socketOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return groupSocketURL()
    }
    #endif

    /// `bridge.sock` in the App Group container, which only our signed apps can reach.
    static func groupSocketURL() -> URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Group Containers/\(appGroup)")
        return container.appending(path: "bridge.sock")
    }
}
