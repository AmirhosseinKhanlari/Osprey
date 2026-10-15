import Darwin
import Foundation

/// What media downloads leave running or on disk, so quitting can stop and delete it.
///
/// - Every yt-dlp / ffmpeg child leads its own process group, so the app's own exit doesn't take it down: each one is
///   registered from spawn until its owner has finished with the group, and `terminateAll()` SIGKILLs them all.
/// - Every cookie file is registered from write to delete, and `terminateAll()` deletes what's left.
/// - `sweepLeftovers` cleans up after earlier runs (or a crash) at launch.
public final class MediaCleanup: @unchecked Sendable {
    /// The registry the app's processes and cookie files use.
    public static let shared = MediaCleanup()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: ChildProcess] = [:]
    private var jars: [String: URL] = [:]
    /// After `terminateAll()`, anything registered late (a spawn racing the quit) is stopped or deleted at once.
    private var terminated = false

    init() {}

    // MARK: Registry

    func register(_ child: ChildProcess) {
        let late = lock.withLock { () -> Bool in
            if terminated { return true }
            processes[ObjectIdentifier(child)] = child
            return false
        }
        if late { child.signalGroup(SIGKILL) }
    }

    func unregister(_ child: ChildProcess) {
        _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(child)) }
    }

    func register(_ jar: CookieJarFile) {
        let folder = jar.url.deletingLastPathComponent()
        let late = lock.withLock { () -> Bool in
            if terminated { return true }
            jars[folder.path(percentEncoded: false)] = folder
            return false
        }
        if late { try? FileManager.default.removeItem(at: folder) }
    }

    func unregister(_ jar: CookieJarFile) {
        _ = lock.withLock { jars.removeValue(forKey: jar.url.deletingLastPathComponent().path(percentEncoded: false)) }
    }

    func isTracking(_ child: ChildProcess) -> Bool { lock.withLock { processes[ObjectIdentifier(child)] != nil } }

    func isTracking(_ jar: CookieJarFile) -> Bool {
        lock.withLock { jars[jar.url.deletingLastPathComponent().path(percentEncoded: false)] != nil }
    }

    var trackedProcessCount: Int { lock.withLock { processes.count } }

    // MARK: Quit

    /// Synchronously SIGKILLs every registered process group and deletes every live cookie file. For
    /// `applicationWillTerminate`: nothing here waits, and later registrations are handled at once.
    public func terminateAll() {
        let (children, folders) = lock.withLock { () -> ([ChildProcess], [URL]) in
            terminated = true
            defer { processes = [:]; jars = [:] }
            return (Array(processes.values), Array(jars.values))
        }
        for child in children {
            child.signalGroup(SIGKILL)
            kill(child.pid, SIGKILL)               // in case the leader left its group
        }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    /// `shared.terminateAll()`.
    public static func terminateAll() { shared.terminateAll() }

    // MARK: Partial files

    /// Extended attribute on every `<name>.osprey-partial.<ext>` Osprey creates. The sweep needs both the name and it.
    public static let partialAttribute = "com.akhanlari.osprey.partial"

    /// Marks `url` as Osprey's own partial file.
    public static func markAsPartial(_ url: URL) throws {
        let value = Array("1".utf8)
        guard setxattr(url.path(percentEncoded: false), partialAttribute, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw MediaError.muxFailed("couldn't mark the output file")
        }
    }

    /// Removes the mark (from a finished file, which was renamed from its partial and kept its attributes).
    public static func unmarkPartial(_ url: URL) {
        _ = removexattr(url.path(percentEncoded: false), partialAttribute, XATTR_NOFOLLOW)
    }

    public static func isMarkedPartial(_ url: URL) -> Bool { isMarked(url, attribute: partialAttribute) }

    static func isMarked(_ url: URL, attribute: String) -> Bool {
        getxattr(url.path(percentEncoded: false), attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    // MARK: Two running copies

    /// One lock file per running copy (`<folder>/<pid>.lock`, held with `flock`), so a second copy (say a Debug build
    /// next to the installed one) never sweeps the first one's live cookie and part folders.
    public final class RunLock: @unchecked Sendable {
        /// `~/Library/Application Support/Osprey/run`.
        public static var defaultFolder: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Osprey/run", directoryHint: .isDirectory)
        }

        private let fd: Int32
        private let url: URL
        private let lock = NSLock()
        private var released = false

        private init(fd: Int32, url: URL) { self.fd = fd; self.url = url }

        /// Takes this copy's lock; nil when it can't (the sweep is then skipped).
        public static func acquire(in folder: URL = defaultFolder, pid: pid_t = getpid()) -> RunLock? {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(pid).lock")
            let path = url.path(percentEncoded: false)
            // Another copy may remove a stale file between our open and flock: keep the lock only if the locked file is
            // still the one at the path (same device and inode), else try again.
            for _ in 0..<3 {
                let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return nil }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
                var locked = stat(), current = stat()
                if fstat(fd, &locked) == 0, stat(path, &current) == 0, locked.st_dev == current.st_dev, locked.st_ino == current.st_ino {
                    return RunLock(fd: fd, url: url)
                }
                close(fd)
            }
            return nil
        }

        /// True while another copy holds its lock. Lock files nobody holds (a copy that crashed) are removed.
        public static func otherCopiesRunning(in folder: URL = defaultFolder, excluding pid: pid_t = getpid()) -> Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            var running = false
            for name in names where name.hasSuffix(".lock") && name != "\(pid).lock" {
                let path = folder.appending(path: name).path(percentEncoded: false)
                let fd = open(path, O_RDWR | O_CLOEXEC)
                guard fd >= 0 else { continue }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    unlink(path)                   // stale: nobody holds it
                    flock(fd, LOCK_UN)
                } else {
                    running = true
                }
                close(fd)
            }
            return running
        }

        public func release() {
            let first = lock.withLock { () -> Bool in defer { released = true }; return !released }
            guard first else { return }
            unlink(url.path(percentEncoded: false))
            flock(fd, LOCK_UN)
            close(fd)
        }

        deinit { release() }
    }

    // MARK: Launch sweep

    private static let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// The names and mark a copy of the app gives its leftovers. `current` is Osprey's; the first-launch cleanup of the
    /// former app's leftovers passes that app's set, so both sweeps follow exactly the same rules.
    public struct LeftoverNames: Sendable {
        /// `<cookiePrefix><uuid>` folders in the temporary folder.
        public let cookiePrefix: String
        /// `<hiddenFolderPrefix><uuid>` part folders in the media folders.
        public let hiddenFolderPrefix: String
        /// `<name>.<partialInfix>.<ext>` merges in the media folders.
        public let partialInfix: String
        /// The extended attribute every such merge carries.
        public let partialAttribute: String

        public init(cookiePrefix: String, hiddenFolderPrefix: String, partialInfix: String, partialAttribute: String) {
            self.cookiePrefix = cookiePrefix
            self.hiddenFolderPrefix = hiddenFolderPrefix
            self.partialInfix = partialInfix
            self.partialAttribute = partialAttribute
        }

        public static let current = LeftoverNames(cookiePrefix: "osprey-cookies-", hiddenFolderPrefix: ".osprey-media-",
                                                  partialInfix: "osprey-partial", partialAttribute: MediaCleanup.partialAttribute)

        var cookieFolder: NSRegularExpression {
            try! NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: cookiePrefix))\(MediaCleanup.uuid)$")
        }
        var hiddenFolder: NSRegularExpression {
            try! NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: hiddenFolderPrefix))\(MediaCleanup.uuid)$")
        }
        /// Muxer's `<name>.<partialInfix>.<ext>` (the extension is letters and digits only).
        var partialFile: NSRegularExpression {
            try! NSRegularExpression(pattern: #"^.+\."# + NSRegularExpression.escapedPattern(for: partialInfix) + #"\.[A-Za-z0-9]{1,10}$"#)
        }
    }
    /// What a part folder holds: the parts (`video.*`, `audio.*`), a subtitle, and the engine's or yt-dlp's work files
    /// next to them (`video.mp4.slpart`, `.slpart.json`, `.part`, `.part-Frag3`, `.ytdl`, `video.temp.mp4`).
    private static let partFile = try! NSRegularExpression(pattern: #"^(video|audio|subtitle)\.[A-Za-z0-9._-]{1,80}$"#)

    /// Deletes what earlier runs left, and only that. Each item must be older than `cutoff` (the launch), and symbolic
    /// links are never followed or removed:
    /// - in `temporaryFolder`: `osprey-cookies-<uuid>` folders that hold only `cookies.txt`;
    /// - directly in each of `folders` (the media folders) or one of their immediate subfolders (a playlist's folder):
    ///   `<name>.osprey-partial.<ext>` files carrying `partialAttribute`, and `.osprey-media-<uuid>` folders that
    ///   hold only part files. A folder is emptied file by file and then removed; nothing else is ever recursed into.
    /// A `.osprey-media-<uuid>` folder whose uuid is in `keeping` (a restored download's parts) is never removed.
    /// Returns what was removed.
    @discardableResult
    public static func sweepLeftovers(in folders: [URL], temporaryFolder: URL = FileManager.default.temporaryDirectory,
                                      olderThan cutoff: Date, names: LeftoverNames = .current,
                                      keeping restored: Set<UUID> = []) -> [URL] {
        let cookieFolder = names.cookieFolder
        var removed: [URL] = []
        for item in entries(of: temporaryFolder) where item.isDirectory && matches(cookieFolder, item.name) && item.modified < cutoff {
            if removeFolder(item.url, olderThan: cutoff, onlyHolding: { $0 == "cookies.txt" }) { removed.append(item.url) }
        }
        var seen = Set<String>()
        for folder in folders {
            let key = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            guard seen.insert(key).inserted else { continue }
            let top = entries(of: folder)
            removed += sweep(top, olderThan: cutoff, names: names, keeping: restored)
            for sub in top where sub.isDirectory && !sub.name.hasPrefix(".") {
                removed += sweep(entries(of: sub.url), olderThan: cutoff, names: names, keeping: restored)
            }
        }
        return removed
    }

    private static func sweep(_ items: [Entry], olderThan cutoff: Date, names: LeftoverNames, keeping restored: Set<UUID>) -> [URL] {
        let partialFile = names.partialFile, hiddenFolder = names.hiddenFolder
        var removed: [URL] = []
        for item in items where item.modified < cutoff {
            if item.isRegularFile, matches(partialFile, item.name), isMarked(item.url, attribute: names.partialAttribute),
               (try? FileManager.default.removeItem(at: item.url)) != nil {
                removed.append(item.url)
            } else if item.isDirectory, matches(hiddenFolder, item.name),
                      !isRestored(item.name, prefix: names.hiddenFolderPrefix, restored: restored),
                      removeFolder(item.url, olderThan: cutoff, onlyHolding: { matches(partFile, $0) || $0 == ".DS_Store" }) {
                removed.append(item.url)
            }
        }
        return removed
    }

    /// True for `<prefix><uuid>` when the uuid is a restored download's: its parts are still needed.
    private static func isRestored(_ name: String, prefix: String, restored: Set<UUID>) -> Bool {
        guard !restored.isEmpty, name.hasPrefix(prefix),
              let id = UUID(uuidString: String(name.dropFirst(prefix.count))) else { return false }
        return restored.contains(id)
    }

    /// Removes `folder` only if every item in it is a regular file older than `cutoff` whose name `allowed` accepts: those
    /// files one by one, then the (now empty) folder. Anything else (a subfolder, a link, another file, a file still being
    /// written) leaves the folder untouched.
    private static func removeFolder(_ folder: URL, olderThan cutoff: Date, onlyHolding allowed: (String) -> Bool) -> Bool {
        let items = entries(of: folder)
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.count == items.count,
              items.allSatisfy({ $0.isRegularFile && $0.modified < cutoff && allowed($0.name) }) else { return false }
        for item in items where unlink(item.url.path(percentEncoded: false)) != 0 { return false }
        return rmdir(folder.path(percentEncoded: false)) == 0
    }

    private struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isRegularFile: Bool
        let modified: Date
    }

    /// The folder's items (none for a missing folder). Symbolic links come back as neither directory nor file.
    private static func entries(of folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let link = values.isSymbolicLink == true
            return Entry(url: url, name: url.lastPathComponent, isDirectory: !link && values.isDirectory == true,
                         isRegularFile: !link && values.isRegularFile == true, modified: values.contentModificationDate ?? .distantFuture)
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ name: String) -> Bool {
        regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
