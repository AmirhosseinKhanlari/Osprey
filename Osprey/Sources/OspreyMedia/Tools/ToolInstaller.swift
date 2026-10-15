import CryptoKit
import Foundation

/// Where a managed tool is downloaded from, and where its SHA-256 checksum is published.
public struct ToolSource: Sendable, Equatable {
    public enum Arch: Sendable { case arm64, x86_64

        public static var current: Arch {
            #if arch(arm64)
            .arm64
            #else
            .x86_64
            #endif
        }
    }

    public var binaryURL: URL
    public var checksumURL: URL
    /// The file name to look for in the checksum file.
    public var checksumEntryName: String
    /// A zip archive; the tool is the member named after it, found by name anywhere inside.
    public var archive: Bool
    /// The SHA-256 the download must have, hard-coded for a pinned build. The published checksum must agree with it.
    public var expectedSHA256: String?

    public init(binaryURL: URL, checksumURL: URL, checksumEntryName: String, archive: Bool, expectedSHA256: String? = nil) {
        self.binaryURL = binaryURL
        self.checksumURL = checksumURL
        self.checksumEntryName = checksumEntryName
        self.archive = archive
        self.expectedSHA256 = expectedSHA256
    }

    /// yt-dlp's standalone macOS release, checked against the release's SHA2-256SUMS.
    public static let ytdlp = ToolSource(
        binaryURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
        checksumURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!,
        checksumEntryName: "yt-dlp_macos", archive: false)

    /// SHA-256 of the pinned ffmpeg 9.0.2 zips. Taken from the builds' `.sha256` files on 2026-10-14 and confirmed by
    /// hashing a download of each zip. A download must match these AND the published `.sha256`.
    static let ffmpegARM64SHA256 = "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
    static let ffmpegX86_64SHA256 = "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4"

    /// LICENCE — must be confirmed before Install is offered widely. These are GPL builds (`--enable-gpl
    /// --enable-version3`, so GPLv3; they include libx264, libx265 and libmp3lame). Osprey never bundles or
    /// redistributes them: the user's Mac downloads the build from its publisher at run time and runs it only as a
    /// separate process.
    /// Source: https://ffmpeg.martin-riedl.de (signed static builds, each zip has a `.sha256` file next to it).
    /// Checked 2026-10-14: release 9.0.2, both zip and .sha256 answer 200 for arm64 and amd64. The URLs are pinned to
    /// that build (not the `/redirect/latest/` ones, whose `.sha256` 404s and which could move between the two downloads).
    /// Bump the build id AND the digests above when updating the pin.
    public static func ffmpeg(arch: Arch) -> ToolSource {
        let (base, digest) = switch arch {
        case .arm64: ("https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip", ffmpegARM64SHA256)
        case .x86_64: ("https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2/ffmpeg.zip", ffmpegX86_64SHA256)
        }
        return ToolSource(binaryURL: URL(string: base)!, checksumURL: URL(string: base + ".sha256")!,
                          checksumEntryName: "ffmpeg.zip", archive: true, expectedSHA256: digest)
    }
}

/// Downloads yt-dlp and ffmpeg into the managed folder. Nothing is chmod'ed or run until its SHA-256 matches.
public struct ToolInstaller: Sendable {
    static let lastCheckKey = "mediaToolsLastUpdateCheck"
    static let updateInterval: TimeInterval = 24 * 3600

    private let tools: MediaTools
    private let session: URLSession
    /// UserDefaults is thread-safe; the SDK just does not mark it Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let ytdlpSource: ToolSource

    /// After a failed managed install, how long another copy (Homebrew) is used without trying again.
    static let installBackoff: TimeInterval = 10 * 60
    private let now: @Sendable () -> Date

    public init(tools: MediaTools, session: URLSession = .shared, defaults: UserDefaults = .standard,
                ytdlpSource: ToolSource = .ytdlp, now: @escaping @Sendable () -> Date = { Date() }) {
        self.tools = tools
        self.session = session
        self.defaults = defaults
        self.ytdlpSource = ytdlpSource
        self.now = now
    }

    /// A managed install of `tool` failed less than ten minutes ago (say, offline).
    public func isInstallBackedOff(_ tool: MediaTool) -> Bool {
        guard let failed = defaults.object(forKey: failureKey(tool)) as? Date else { return false }
        let elapsed = now().timeIntervalSince(failed)
        return elapsed >= 0 && elapsed < Self.installBackoff
    }

    /// How long until another managed install of `tool` is tried; nil when it isn't backed off.
    public func installBackoffRemaining(_ tool: MediaTool) -> TimeInterval? {
        guard isInstallBackedOff(tool), let failed = defaults.object(forKey: failureKey(tool)) as? Date else { return nil }
        return max(0, Self.installBackoff - now().timeIntervalSince(failed))
    }

    /// When the managed yt-dlp was last checked for an update successfully; nil if never.
    public var lastUpdateCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    /// Settings' "Update now": downloads the latest yt-dlp over the managed copy, whatever the last check was, and
    /// records the check. A failure starts the install backoff and leaves the old copy in place. Homebrew is never touched.
    public func updateNow(progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation {
        let source = ytdlpSource
        do {
            // Shares the key with updateIfDue and every other yt-dlp install: one download at a time.
            let location = try await InstallCoordinator.shared.run(key: key(.ytdlp)) {
                let location = try await performInstall(.ytdlp, from: source, progress: progress)
                defaults.set(now(), forKey: Self.lastCheckKey)
                return location
            }
            defaults.removeObject(forKey: failureKey(.ytdlp))
            return location
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            defaults.set(now(), forKey: failureKey(.ytdlp))
            throw error
        }
    }

    private func failureKey(_ tool: MediaTool) -> String { "mediaToolsInstallFailedAt.\(tool.fileName)" }

    /// The tool where it already is, otherwise freshly installed. Concurrent callers share one download.
    public func ensure(_ tool: MediaTool) async throws -> ToolLocation {
        if let found = tools.locate(tool) { return found }
        let source = tool == .ytdlp ? ytdlpSource : ToolSource.ffmpeg(arch: .current)
        return try await InstallCoordinator.shared.run(key: key(tool)) {
            if let found = tools.locate(tool) { return found }
            return try await performInstall(tool, from: source, progress: { _ in })
        }
    }

    /// Osprey's own copy of `tool`: kept when present, installed otherwise (a Homebrew copy doesn't count, since it
    /// may be stale). When the install fails, say offline, and another copy exists, that copy is returned instead.
    public func ensureManaged(_ tool: MediaTool, progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation {
        if let found = tools.locate(tool), found.source == .managed { return found }
        // Offline a moment ago: use the other copy without waiting on another failing download.
        if isInstallBackedOff(tool), let fallback = tools.locate(tool) { return fallback }
        do {
            return try await installManaged(tool, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let fallback = tools.locate(tool) { return fallback }
            throw error
        }
    }

    /// Installs (or replaces) the managed copy from the pinned source. Concurrent callers share one download.
    public func installManaged(_ tool: MediaTool, progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation {
        let source = tool == .ytdlp ? ytdlpSource : ToolSource.ffmpeg(arch: .current)
        do {
            let location = try await InstallCoordinator.shared.run(key: key(tool)) {
                if let found = tools.locate(tool), found.source == .managed { return found }
                return try await performInstall(tool, from: source, progress: progress)
            }
            defaults.removeObject(forKey: failureKey(tool))
            return location
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            defaults.set(now(), forKey: failureKey(tool))
            throw error
        }
    }

    /// Re-installs the managed yt-dlp at most once per 24 hours after a successful check. Failures are ignored
    /// (the old binary stays and the next launch retries). Homebrew copies are never touched.
    public func updateIfDue(now: Date = .now) async {
        guard let managed = tools.locate(.ytdlp), managed.source == .managed, !checkedRecently(at: now) else { return }
        // The same single-flight key as every other yt-dlp install, so "Update now" during this check joins it.
        _ = try? await InstallCoordinator.shared.run(key: key(.ytdlp)) {
            // A concurrent check that finished a moment ago already did the work.
            if checkedRecently(at: now) { return managed }
            // Reads SHA2-256SUMS first and skips the download when the managed copy is already that release.
            let location = try await performInstall(.ytdlp, from: ytdlpSource, skipIfCurrent: true, progress: { _ in })
            defaults.set(now, forKey: Self.lastCheckKey)
            return location
        }
    }

    private func checkedRecently(at now: Date) -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return false }
        return now.timeIntervalSince(last) < Self.updateInterval && now >= last
    }


    public func install(_ tool: MediaTool, from source: ToolSource,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation {
        try await InstallCoordinator.shared.run(key: key(tool)) {
            try await performInstall(tool, from: source, progress: progress)
        }
    }

    /// One key per tool and folder: installs, updates and the daily check of the same tool never run side by side.
    private func key(_ tool: MediaTool) -> String {
        tools.managedFolder.path(percentEncoded: false) + "|" + tool.fileName
    }

    /// - skipIfCurrent: when the managed copy's SHA-256 already equals the published one, nothing is downloaded.
    private func performInstall(_ tool: MediaTool, from source: ToolSource, skipIfCurrent: Bool = false,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation {
        let fm = FileManager.default
        let staging = tools.managedFolder.appending(path: ".staging", directoryHint: .isDirectory)
        let work = staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: tools.managedFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path(percentEncoded: false))
            Self.removeStale(in: staging)
            try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw MediaError.installFailed("couldn't prepare the tools folder")
        }
        defer { try? fm.removeItem(at: work) }

        // The checksum comes first: it decides whether the binary is needed at all.
        let sums = work.appending(path: "checksums")
        try await download(source.checksumURL, to: sums, progress: { _ in })
        guard let expected = Self.checksum(in: sums, entry: source.checksumEntryName) else {
            throw MediaError.installFailed("no checksum published")
        }
        // A pinned build's digest is hard-coded; the published one must agree with it.
        if let pinned = source.expectedSHA256?.lowercased(), pinned != expected {
            throw MediaError.installFailed("checksum mismatch")
        }
        let destination = tools.managedFolder.appending(path: tool.fileName)
        if skipIfCurrent, !source.archive, (try? Self.sha256(of: destination)) == expected {
            progress(1)
            return ToolLocation(url: destination, source: .managed)
        }

        let downloaded = work.appending(path: "download")
        try await download(source.binaryURL, to: downloaded, progress: progress)

        // Verify before anything else touches the file: no chmod, no unzip, no execution.
        guard try Self.sha256(of: downloaded) == expected else {
            try? fm.removeItem(at: downloaded)
            throw MediaError.installFailed("checksum mismatch")
        }

        let candidate: URL
        if source.archive {
            let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                     ["-x", "-k", downloaded.path(percentEncoded: false), unpacked.path(percentEncoded: false)],
                                                     timeout: 120)
            } catch is CancellationError { throw CancellationError() } catch {
                throw MediaError.installFailed("couldn't unpack the download")
            }
            guard result.status == 0, let found = Self.find(named: tool.fileName, in: unpacked) else {
                throw MediaError.installFailed("couldn't unpack the download")
            }
            candidate = found
        } else {
            candidate = downloaded
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path(percentEncoded: false))

        // Prove the verified binary starts before it replaces a working one. 60 s covers a cold PyInstaller start
        // while Gatekeeper scans the file.
        let run: ProcessResult
        do {
            run = try await ProcessRunner.run(candidate, tool.versionArguments, timeout: 60)
        } catch is CancellationError { throw CancellationError() } catch {
            throw MediaError.installFailed("the new version doesn't start")
        }
        guard run.status == 0 else { throw MediaError.installFailed("the new version doesn't start") }

        do {
            do {
                if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                    _ = try fm.replaceItemAt(destination, withItemAt: candidate)
                } else {
                    try fm.moveItem(at: candidate, to: destination)
                }
            } catch where fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                // Someone else put a copy there in the meantime; swap atomically.
                _ = try fm.replaceItemAt(destination, withItemAt: candidate)
            }
        } catch {
            throw MediaError.installFailed("couldn't put the tool in place")
        }
        return ToolLocation(url: destination, source: .managed)
    }

    /// Deletes `.staging` subfolders left behind by crashed installs (older than an hour).
    private static func removeStale(in staging: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        guard let items = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: Helpers

    private func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        do {
            let delegate = ProgressDelegate(progress)
            let (temp, response) = try await session.download(from: url, delegate: delegate)
            defer { try? fm.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw MediaError.installFailed("download failed")
            }
            try fm.moveItem(at: temp, to: file)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
            progress(1)
        } catch let error as MediaError {
            try? fm.removeItem(at: file)
            throw error
        } catch let error as URLError where error.code == .cancelled {
            try? fm.removeItem(at: file)
            throw CancellationError()
        } catch is CancellationError {
            try? fm.removeItem(at: file)
            throw CancellationError()
        } catch {
            try? fm.removeItem(at: file)
            throw MediaError.installFailed("download failed")
        }
    }

    /// Finds `<hex>  <name>` (or `<hex> *<name>`) for `entry`; returns the lowercase hex digest.
    /// Several entries for the name with different digests are ambiguous and rejected.
    static func checksum(in file: URL, entry: String) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var found = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            let hex = parts[0].lowercased()
            if name == entry, hex.count == 64, hex.allSatisfy(\.isHexDigit) { found.insert(hex) }
        }
        return found.count == 1 ? found.first : nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func find(named name: String, in folder: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return url }
        }
        return nil
    }
}

/// Reports a download's fraction completed.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = report
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
    }
}

/// Process-wide single flight: concurrent callers with the same key join one running operation. It is typed to
/// `ToolLocation` on purpose: a generic result type let a caller whose closure inferred another type miss the
/// running task and start a second download.
actor InstallCoordinator {
    static let shared = InstallCoordinator()
    private var running: [String: Task<ToolLocation, Error>] = [:]

    func run(key: String, _ operation: @escaping @Sendable () async throws -> ToolLocation) async throws -> ToolLocation {
        if let existing = running[key] { return try await existing.value }
        let task = Task.detached { try await operation() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
