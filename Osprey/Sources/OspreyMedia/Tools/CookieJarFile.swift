import Foundation

/// A Netscape-format cookie file in a private (0700) temporary folder. Delete it as soon as the tool is done.
public struct CookieJarFile: Sendable {
    public let url: URL

    public static func write(cookieHeader: String, for pageURL: URL) throws -> CookieJarFile {
        guard let host = pageURL.host(percentEncoded: false), !host.isEmpty else {
            throw MediaError.extractionFailed("invalid address")
        }
        let secure = pageURL.scheme?.lowercased() == "https" ? "TRUE" : "FALSE"
        var lines = ["# Netscape HTTP Cookie File"]
        for pair in cookieHeader.components(separatedBy: "; ") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
            guard !name.isEmpty, !Self.hasControl(name), !Self.hasControl(value) else { continue }
            lines.append(".\(host)\tTRUE\t/\t\(secure)\t0\t\(name)\t\(value)")
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "osprey-cookies-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: "cookies.txt")
        do {
            guard fm.createFile(atPath: file.path(percentEncoded: false), contents: Data((lines.joined(separator: "\n") + "\n").utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                throw MediaError.extractionFailed("couldn't write cookies")
            }
            // createFile honours the umask; make the modes exact.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        let jar = CookieJarFile(url: file)
        MediaCleanup.shared.register(jar)           // deleted on quit if its owner hasn't yet
        return jar
    }

    private static func hasControl(_ s: String) -> Bool {
        s.contains { $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        MediaCleanup.shared.unregister(self)
    }
}
