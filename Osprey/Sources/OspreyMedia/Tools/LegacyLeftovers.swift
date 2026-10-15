import Foundation

/// The one-time cleanup of what the app's former name, Slipstream, left behind after a crash: its marked merges, its
/// hidden part folders and its cookie folders. Part of the first-launch migration, and with `LegacyMigration` the only
/// code that names the old identifiers.
public enum LegacyLeftovers {
    /// The former app's bundle ID, to tell whether it is still running.
    public static let legacyAppBundleID = "com.akhanlari.slipstream"

    /// The former app's leftover names and mark. Only files carrying `com.akhanlari.slipstream.partial` are swept.
    public static let names = MediaCleanup.LeftoverNames(cookiePrefix: "slipstream-cookies-",
                                                         hiddenFolderPrefix: ".slipstream-media-",
                                                         partialInfix: "slipstream-partial",
                                                         partialAttribute: "com.akhanlari.slipstream.partial")

    /// `~/Library/Application Support/Slipstream/run`, where each running copy of the former app holds a lock.
    public static var legacyRunFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Slipstream/run", directoryHint: .isDirectory)
    }

    /// True while a copy of the former app holds its run lock. Unlike `RunLock.otherCopiesRunning` it only looks:
    /// the former app's folder is left exactly as it was.
    public static func legacyAppHoldsRunLock(in folder: URL = legacyRunFolder) -> Bool {
        let lockNames = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in lockNames where name.hasSuffix(".lock") {
            let fd = open(folder.appending(path: name).path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }   // held: that copy is running
            flock(fd, LOCK_UN)
        }
        return false
    }

    /// Sweeps the former app's leftovers with the same rules as Osprey's own launch sweep (same places, older than
    /// `cutoff`, marked merges only, folders holding only part files, no links followed). Returns nil without touching
    /// anything while the former app runs (`legacyAppRunning`, or its run lock is held), so it can be tried again later.
    public static func sweep(in folders: [URL], temporaryFolder: URL = FileManager.default.temporaryDirectory,
                             olderThan cutoff: Date, legacyRunFolder: URL = legacyRunFolder,
                             legacyAppRunning: Bool) -> [URL]? {
        guard !legacyAppRunning, !legacyAppHoldsRunLock(in: legacyRunFolder) else { return nil }
        return MediaCleanup.sweepLeftovers(in: folders, temporaryFolder: temporaryFolder, olderThan: cutoff, names: names)
    }
}
