import Foundation
import OspreyBridge
import Testing
@testable import OspreyIntegration

@Suite struct NativeHostInstallerTests {
    func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "Library/Application Support/Google/Chrome"),
                                                withIntermediateDirectories: true)
        return home
    }

    let host = URL(fileURLWithPath: "/Applications/Osprey.app/Contents/MacOS/osprey-host")

    @Test func writesOnlyForInstalledBrowsers() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let written = try NativeHostInstaller(home: home).install(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])
        #expect(written.map(\.lastPathComponent) == ["com.akhanlari.osprey.host.json"])
        #expect(written.first?.path(percentEncoded: false).contains("Google/Chrome/NativeMessagingHosts") == true)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Library/Application Support/Microsoft Edge").path(percentEncoded: false)))
    }

    @Test func manifestHasTheChromeFormat() throws {
        let data = try NativeHostInstaller.manifest(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] as? String == "com.akhanlari.osprey.host")
        #expect(object["type"] as? String == "stdio")
        #expect(object["path"] as? String == "/Applications/Osprey.app/Contents/MacOS/osprey-host")
        #expect(object["allowed_origins"] as? [String] == ["chrome-extension://hdaelhdfolkmnghifnpopgadkndofanj/"])
        #expect(object["description"] as? String == "Osprey download manager")
    }

    @Test func repairsAStaleManifestAndLeavesAGoodOneAlone() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = NativeHostInstaller(home: home)
        let manifestURL = try #require(try installer.install(hostExecutable: URL(fileURLWithPath: "/old/path"), allowedOrigins: []).first)
        try installer.install(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])
        let repaired = try Data(contentsOf: manifestURL)
        #expect(repaired == (try NativeHostInstaller.manifest(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])))
        let stamp = try FileManager.default.attributesOfItem(atPath: manifestURL.path(percentEncoded: false))[.modificationDate] as? Date
        try installer.install(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])
        let again = try FileManager.default.attributesOfItem(atPath: manifestURL.path(percentEncoded: false))[.modificationDate] as? Date
        #expect(stamp == again)
    }

    @Test func oneBrokenBrowserDoesNotBlockTheOthers() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "Library/Application Support")
        try FileManager.default.createDirectory(at: support.appending(path: "Microsoft Edge"), withIntermediateDirectories: true)
        // A regular file where Chrome's NativeMessagingHosts folder should be, so createDirectory fails for Chrome.
        try Data().write(to: support.appending(path: "Google/Chrome/NativeMessagingHosts"))
        let edgeManifest = support.appending(path: "Microsoft Edge/NativeMessagingHosts/com.akhanlari.osprey.host.json")

        var caught: NativeHostInstallError?
        do {
            try NativeHostInstaller(home: home).install(hostExecutable: host, allowedOrigins: [BridgeLocation.chromeExtensionOrigin])
        } catch let error as NativeHostInstallError {
            caught = error
        }
        let error = try #require(caught)
        #expect(error.written.map { $0.path(percentEncoded: false) } == [edgeManifest.path(percentEncoded: false)])
        #expect(FileManager.default.fileExists(atPath: edgeManifest.path(percentEncoded: false)))
        #expect(error.failures.map(\.folder) == ["Google/Chrome"])
    }

    @Test func manifestPathWithSpacesRoundTrips() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let spaced = URL(fileURLWithPath: "/Applications/My Apps/Osprey.app/Contents/MacOS/osprey-host")
        let written = try #require(try NativeHostInstaller(home: home).install(hostExecutable: spaced, allowedOrigins: []).first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any])
        #expect(object["path"] as? String == "/Applications/My Apps/Osprey.app/Contents/MacOS/osprey-host")
    }
}
