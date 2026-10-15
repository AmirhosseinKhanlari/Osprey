import Foundation
import OspreyBridge

/// Thrown by `install` when at least one browser folder could not be written.
/// The other browsers are still installed; `written` lists their manifest URLs.
public struct NativeHostInstallError: Error, Sendable {
    public struct Failure: Sendable {
        public let folder: String
        public let message: String
    }

    public let written: [URL]
    public let failures: [Failure]
}

/// Writes Chrome's native-messaging host manifest for every installed Chromium browser.
/// The app calls it on each launch, so the manifests are repaired if anything changes them.
public struct NativeHostInstaller: Sendable {
    /// Application Support sub-folders of supported browsers. Arc is added once its folder is verified.
    public static let browserFolders = ["Google/Chrome", "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser"]

    private struct Manifest: Encodable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case name, description, path, type
            case allowedOrigins = "allowed_origins"
        }
    }

    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    @discardableResult
    public func install(hostExecutable: URL, allowedOrigins: [String]) throws -> [URL] {
        let data = try Self.manifest(hostExecutable: hostExecutable, allowedOrigins: allowedOrigins)
        var written: [URL] = []
        var failures: [NativeHostInstallError.Failure] = []
        for folder in Self.browserFolders {
            let browser = home.appending(path: "Library/Application Support/\(folder)")
            guard FileManager.default.fileExists(atPath: browser.path(percentEncoded: false)) else { continue }
            do {
                let hosts = browser.appending(path: "NativeMessagingHosts")
                try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
                let url = hosts.appending(path: "\(BridgeLocation.nativeHostName).json")
                if (try? Data(contentsOf: url)) != data {
                    try data.write(to: url, options: .atomic)
                }
                written.append(url)
            } catch {
                // One broken browser folder must not block the browsers after it.
                failures.append(.init(folder: folder, message: String(describing: error)))
            }
        }
        guard failures.isEmpty else {
            throw NativeHostInstallError(written: written, failures: failures)
        }
        return written
    }

    public static func manifest(hostExecutable: URL, allowedOrigins: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Manifest(name: BridgeLocation.nativeHostName, description: "Osprey download manager",
                                           path: hostExecutable.path(percentEncoded: false), type: "stdio",
                                           allowedOrigins: allowedOrigins))
    }
}
