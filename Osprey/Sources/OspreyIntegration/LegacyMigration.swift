import Foundation
import OspreyBridge

/// Brings the user's data over from the app's former name, Slipstream, the first time Osprey runs.
///
/// Slipstream kept its state in three places, and Osprey has a new home for each:
/// - the `com.akhanlari.slipstream` defaults (settings, media choices, window frames) → Osprey's own defaults;
/// - `~/Library/Application Support/Slipstream` (the managed yt-dlp and ffmpeg in `Tools`) → `…/Osprey`;
/// - the `8CG9QYMSR5.com.akhanlari.slipstream` App Group, which only ever held the live bridge socket: nothing to copy.
///
/// Everything is copied, never moved: the old data stays where it is. A setting is copied only when Osprey has no value
/// for it, a file only when Osprey has none at that path, and a stored path is rewritten only when it points into one of
/// Slipstream's own folders, so a folder the user chose keeps its path. `didShowSafariSetup` is never copied: the
/// renamed Safari extension is a new extension, off until the user turns it on, so Osprey must offer its setup again.
/// Each file is copied under a hidden temporary name and then renamed into place, so an interrupted copy never leaves
/// a cut-off executable at a tool's path. The old Chrome-family native-messaging manifests are deleted, since they
/// launch the old app.
///
/// The migration has three steps (settings, files, browser manifests), and each records its own completion: a finished
/// step never runs again, so nothing the app or the user removes afterwards comes back. A step that fails is tried again
/// on the next launch, at most `maxAttempts` times in all; then it is given up (and logged by the caller through the
/// outcome). The files step also remembers every file it has handled, so a retry never copies one of those again.
/// `doneKey` is set once every step has finished or been given up.
///
/// This file and its tests are the only places that name the old identifiers.
public struct LegacyMigration: @unchecked Sendable {
    public static let legacyDefaultsDomain = "com.akhanlari.slipstream"
    public static let legacyAppGroup = "8CG9QYMSR5.com.akhanlari.slipstream"
    public static let legacySupportFolderName = "Slipstream"
    public static let legacyNativeHostName = "com.akhanlari.slipstream.host"
    public static let supportFolderName = "Osprey"
    /// Set in Osprey's defaults once every step has finished or been given up. Nothing runs after that.
    public static let doneKey = "legacyMigrationDone"
    /// A step tried this many times without success is given up.
    public static let maxAttempts = 3
    /// Relative paths the files step has copied or found in place; a retry leaves them alone even if they're gone since.
    static let handledFilesKey = "legacyMigration.files.handled"

    public enum Step: String, CaseIterable, Sendable {
        case settings, files, manifests

        var doneKey: String { "legacyMigration.\(rawValue).done" }
        var attemptsKey: String { "legacyMigration.\(rawValue).attempts" }
    }
    /// Entries of the old Application Support folder that are never copied: the old app's run locks.
    static let skippedSupportEntries: Set<String> = ["run"]
    /// Settings that are never copied. The renamed Safari extension starts switched off, so the setup prompt must show.
    static let skippedKeys: Set<String> = ["didShowSafariSetup"]
    /// Infix of the temporary name a file is copied under before it is renamed into place.
    static let importInfix = ".osprey-import-"

    public struct Outcome: Sendable, Equatable {
        /// The migration had already run; nothing was looked at.
        public var alreadyDone = false
        /// Defaults keys copied from the old domain (those Osprey had no value for).
        public var copiedKeys: [String] = []
        /// Copied keys whose path pointed into an old folder and now points into Osprey's.
        public var rewrittenKeys: [String] = []
        /// Paths copied into Osprey's Application Support folder, relative to it.
        public var copiedFiles: [String] = []
        /// Old native-messaging manifests that were deleted.
        public var removedManifests: [URL] = []
        public var failures: [String] = []
        /// Steps that failed for the `maxAttempts`-th time in this run and were given up.
        public var gaveUp: [Step] = []

        public var summary: String {
            if alreadyDone { return "already done" }
            return "\(copiedKeys.count) settings (\(rewrittenKeys.count) paths rewritten), \(copiedFiles.count) files, "
                + "\(removedManifests.count) old browser manifests removed, \(failures.count) failures"
                + (failures.isEmpty ? "" : ": " + failures.joined(separator: "; "))
                + (gaveUp.isEmpty ? "" : "; gave up after \(LegacyMigration.maxAttempts) attempts on: "
                    + gaveUp.map(\.rawValue).joined(separator: ", "))
        }
    }

    private let home: URL
    private let defaults: UserDefaults
    private let domain: String
    private let legacyDomain: String

    /// - Parameters:
    ///   - home: the user's home folder; tests pass a temporary one.
    ///   - defaults: Osprey's defaults, written to and holding the done flag.
    ///   - domain: the defaults domain `defaults` writes to (the bundle ID for `.standard`), checked key by key.
    ///   - legacyDomain: the old defaults domain, read with `persistentDomain(forName:)`.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard,
                domain: String = BridgeLocation.appBundleID, legacyDomain: String = LegacyMigration.legacyDefaultsDomain) {
        self.home = home
        self.defaults = defaults
        self.domain = domain
        self.legacyDomain = legacyDomain
    }

    private var homePath: String { home.path(percentEncoded: false) }
    private func inHome(_ relative: String) -> String { (homePath as NSString).appendingPathComponent(relative) }
    var legacySupportPath: String { inHome("Library/Application Support/\(Self.legacySupportFolderName)") }
    var supportPath: String { inHome("Library/Application Support/\(Self.supportFolderName)") }
    var legacyGroupPath: String { inHome("Library/Group Containers/\(Self.legacyAppGroup)") }
    var groupPath: String { inHome("Library/Group Containers/\(BridgeLocation.appGroup)") }

    /// Old default locations and their new ones. A stored path equal to or inside one of these is rewritten.
    var pathMoves: [(from: String, to: String)] { [(legacySupportPath, supportPath), (legacyGroupPath, groupPath)] }

    @discardableResult
    public func run() -> Outcome {
        var outcome = Outcome()
        guard !defaults.bool(forKey: Self.doneKey) else {
            outcome.alreadyDone = true
            return outcome
        }
        for step in Step.allCases where !defaults.bool(forKey: step.doneKey) {
            let failuresBefore = outcome.failures.count
            switch step {
            case .settings: copyDefaults(into: &outcome)
            case .files: copySupportFolder(into: &outcome)
            case .manifests: removeLegacyManifests(into: &outcome)
            }
            if outcome.failures.count == failuresBefore {
                defaults.set(true, forKey: step.doneKey)
                continue
            }
            let attempts = defaults.integer(forKey: step.attemptsKey) + 1
            defaults.set(attempts, forKey: step.attemptsKey)
            if attempts >= Self.maxAttempts {
                defaults.set(true, forKey: step.doneKey)
                outcome.gaveUp.append(step)
            }
        }
        if Step.allCases.allSatisfy({ defaults.bool(forKey: $0.doneKey) }) { defaults.set(true, forKey: Self.doneKey) }
        return outcome
    }

    // MARK: Defaults

    private func copyDefaults(into outcome: inout Outcome) {
        guard let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else { return }
        // Only Osprey's own domain counts, not the global or registration domains `object(forKey:)` would also see.
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        for key in legacy.keys.sorted() where current[key] == nil && !Self.skippedKeys.contains(key) {
            guard let value = legacy[key] else { continue }
            let moved = movingPaths(in: value)
            defaults.set(moved ?? value, forKey: key)
            outcome.copiedKeys.append(key)
            if moved != nil { outcome.rewrittenKeys.append(key) }
        }
    }

    /// `value` with every path into an old folder pointed at the new one, or nil when nothing changed.
    func movingPaths(in value: Any) -> Any? {
        switch value {
        case let string as String:
            return movedPath(string)
        case let array as [Any]:
            let moved = array.map(movingPaths(in:))
            guard moved.contains(where: { $0 != nil }) else { return nil }
            return zip(array, moved).map { $1 ?? $0 }
        case let dictionary as [String: Any]:
            var changed = false
            var result = dictionary
            for (key, item) in dictionary {
                if let moved = movingPaths(in: item) {
                    result[key] = moved
                    changed = true
                }
            }
            return changed ? result : nil
        default:
            return nil
        }
    }

    /// The path in its new place when `path` is an old default location or inside one; nil for any other string.
    func movedPath(_ path: String) -> String? {
        for move in pathMoves where path == move.from || path.hasPrefix(move.from + "/") {
            return move.to + path.dropFirst(move.from.count)
        }
        return nil
    }

    // MARK: Application Support

    private func copySupportFolder(into outcome: inout Outcome) {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: legacySupportPath, isDirectory: &isFolder), isFolder.boolValue else { return }
        copyTree(from: URL(fileURLWithPath: legacySupportPath, isDirectory: true),
                 to: URL(fileURLWithPath: supportPath, isDirectory: true),
                 relative: "", skipping: Self.skippedSupportEntries, into: &outcome)
    }

    /// Copies `source` into `target` entry by entry. Hidden entries (an install's staging folder), anything Osprey
    /// already has, and anything an earlier attempt handled are left alone, so nothing of Osprey's is ever overwritten and
    /// nothing removed since comes back. Folders are created only for a file that is copied. Temporary copies an
    /// interrupted run left in `target` are removed first.
    private func copyTree(from source: URL, to target: URL, relative: String, skipping: Set<String>,
                          into outcome: inout Outcome) {
        let fm = FileManager.default
        do {
            removeInterruptedCopies(in: target)
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles])
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                guard !skipping.contains(name) else { continue }
                let destination = target.appending(path: name)
                let path = relative.isEmpty ? name : relative + "/" + name
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    copyTree(from: entry, to: destination, relative: path, skipping: [], into: &outcome)
                } else if handledFiles.contains(path) {
                    continue                                   // copied before, maybe removed since: never again
                } else if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                    markHandled(path)
                } else {
                    do {
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                        if try copyAtomically(entry, to: destination) { outcome.copiedFiles.append(path) }
                        markHandled(path)
                    } catch {
                        outcome.failures.append("copy \(path): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            outcome.failures.append("copy \(relative.isEmpty ? "support folder" : relative): \(error.localizedDescription)")
        }
    }

    private var handledFiles: Set<String> { Set(defaults.stringArray(forKey: Self.handledFilesKey) ?? []) }

    private func markHandled(_ path: String) {
        defaults.set((handledFiles.union([path])).sorted(), forKey: Self.handledFilesKey)
    }

    /// Copies `source` to a hidden temporary name next to `destination`, then renames it into place without replacing
    /// anything: `destination` only ever appears complete. False when something appeared there meanwhile (kept as is).
    func copyAtomically(_ source: URL, to destination: URL) throws -> Bool {
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent)\(Self.importInfix)\(UUID().uuidString)")
        try fm.copyItem(at: source, to: temporary)
        let tempPath = temporary.path(percentEncoded: false)
        guard renamex_np(tempPath, destination.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            unlink(tempPath)
            if code == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return true
    }

    /// Deletes `.<name>.osprey-import-<uuid>` files an interrupted run left in `folder`. Only that exact pattern.
    func removeInterruptedCopies(in folder: URL) {
        let pattern = #"^\..+"# + NSRegularExpression.escapedPattern(for: Self.importInfix)
            + "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for name in names where regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            unlink(folder.appending(path: name).path(percentEncoded: false))
        }
    }

    // MARK: Browser manifests

    private func removeLegacyManifests(into outcome: inout Outcome) {
        let fm = FileManager.default
        for folder in NativeHostInstaller.browserFolders {
            let manifest = home.appending(path: "Library/Application Support/\(folder)/NativeMessagingHosts/\(Self.legacyNativeHostName).json")
            guard fm.fileExists(atPath: manifest.path(percentEncoded: false)) else { continue }
            do {
                try fm.removeItem(at: manifest)
                outcome.removedManifests.append(manifest)
            } catch {
                outcome.failures.append("remove \(folder) manifest: \(error.localizedDescription)")
            }
        }
    }
}
