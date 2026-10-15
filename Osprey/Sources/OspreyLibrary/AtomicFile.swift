import Darwin
import Foundation
import OspreyEngine

/// The saved files' disk rules, shared by the download list and the queues:
/// - the folder is 0700
/// - a write goes to a temporary file (mode 0600) next to the target, is synced, then renamed over it
/// - a file that can't be read is renamed aside to `<name>.<label>-<date>.json`
enum AtomicFile {
    static func prepareFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
    }

    /// A temporary file created 0600 next to `file`, written and synced, then renamed over `file`.
    static func write(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let tempPath = temp.path(percentEncoded: false)
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(tempPath, file.path(percentEncoded: false)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(tempPath)
            throw error
        }
    }

    /// Deletes `.<fileName>.<uuid>.tmp` files of writes a crash interrupted.
    static func removeStaleTemporaryFiles(in folder: URL, for fileName: String) {
        let fm = FileManager.default
        let prefix = ".\(fileName).", suffix = ".tmp"
        for name in (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            try? fm.removeItem(at: folder.appending(path: name))
        }
    }

    /// Renames `file` (`library.json`) to `library.<label>-<date>.json` beside it and returns the new location.
    @discardableResult
    static func moveAside(_ file: URL, label: String, now: Date) throws -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        let target = FileNaming.uniqueURL(in: file.deletingLastPathComponent(), name: "\(stem).\(label)-\(stamp(now)).json")
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// ISO 8601 basic UTC: `20261014T120000Z`.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
