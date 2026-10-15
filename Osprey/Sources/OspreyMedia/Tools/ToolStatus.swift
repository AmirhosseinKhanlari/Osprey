import Foundation
import Observation

/// What Settings › Media shows about yt-dlp and ffmpeg: where each one is, its version, the last update check,
/// and an install or update in progress. Everything is read from `MediaTools` and the installer's records.
@MainActor @Observable
public final class ToolStatus {
    public struct Row: Equatable, Sendable {
        /// nil: not installed.
        public var source: ToolLocation.Source?
        /// The tool's own version line, trimmed to the version; nil while unknown or when it doesn't run.
        public var version: String?

        public init(source: ToolLocation.Source? = nil, version: String? = nil) {
            self.source = source
            self.version = version
        }
    }

    /// The installer's calls, so a test can stand in for the network.
    public struct Installer: Sendable {
        public var updateYtDlp: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation
        /// Installs Osprey's own copy and throws when that fails (it never falls back to another copy).
        public var installManaged: @Sendable (MediaTool, _ progress: @escaping @Sendable (Double) -> Void) async throws -> ToolLocation
        public var backoffRemaining: @Sendable (MediaTool) -> TimeInterval?
        public var lastUpdateCheck: @Sendable () -> Date?

        public init(updateYtDlp: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> ToolLocation,
                    installManaged: @escaping @Sendable (MediaTool, @escaping @Sendable (Double) -> Void) async throws -> ToolLocation,
                    backoffRemaining: @escaping @Sendable (MediaTool) -> TimeInterval?,
                    lastUpdateCheck: @escaping @Sendable () -> Date?) {
            self.updateYtDlp = updateYtDlp
            self.installManaged = installManaged
            self.backoffRemaining = backoffRemaining
            self.lastUpdateCheck = lastUpdateCheck
        }

        public static func live(_ installer: ToolInstaller) -> Installer {
            Installer(updateYtDlp: { try await installer.updateNow(progress: $0) },
                      installManaged: { try await installer.installManaged($0, progress: $1) },
                      backoffRemaining: { installer.installBackoffRemaining($0) },
                      lastUpdateCheck: { installer.lastUpdateCheck })
        }
    }

    public private(set) var ytdlp = Row()
    public private(set) var ffmpeg = Row()
    /// Set once the first look has finished, so the pane doesn't flash "Not installed".
    public private(set) var loaded = false
    public private(set) var lastUpdateCheck: Date?
    /// An install or update running for the tool; the fraction when known. It only ever grows within a run.
    private var progress: [MediaTool: Double?] = [:]
    private var errors: [MediaTool: String] = [:]
    /// Seconds until another install may be tried, per tool, as of the last look.
    private var backoff: [MediaTool: TimeInterval] = [:]
    /// The running install's token per tool: progress from an older run is dropped.
    private var runs: [MediaTool: UUID] = [:]

    @ObservationIgnored private let tools: MediaTools
    @ObservationIgnored private let installer: Installer
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    public init(tools: MediaTools, installer: Installer) {
        self.tools = tools
        self.installer = installer
    }

    public convenience init(tools: MediaTools) {
        self.init(tools: tools, installer: .live(ToolInstaller(tools: tools)))
    }

    public func row(_ tool: MediaTool) -> Row { tool == .ytdlp ? ytdlp : ffmpeg }
    public func isBusy(_ tool: MediaTool) -> Bool { progress[tool] != nil }
    public func fraction(_ tool: MediaTool) -> Double? { progress[tool] ?? nil }
    public func error(_ tool: MediaTool) -> String? { errors[tool] }
    public func backoffRemaining(_ tool: MediaTool) -> TimeInterval? { backoff[tool] }

    /// Looks at both tools again: where they are, their versions, the last check and any backoff.
    public func refresh() {
        refreshing?.cancel()
        refreshing = Task { await reload() }
    }

    func reload() async {
        let tools = tools
        async let ytdlpVersion = tools.version(.ytdlp)
        async let ffmpegVersion = tools.version(.ffmpeg)
        let (y, f) = await (ytdlpVersion, ffmpegVersion)
        guard !Task.isCancelled else { return }
        ytdlp = Row(source: tools.locate(.ytdlp)?.source, version: Self.shortVersion(y))
        ffmpeg = Row(source: tools.locate(.ffmpeg)?.source, version: Self.shortVersion(f))
        refreshRecords()
        loaded = true
    }

    /// The installer's records only (cheap): the last check and the backoff countdowns.
    public func refreshRecords() {
        lastUpdateCheck = installer.lastUpdateCheck()
        var backoff: [MediaTool: TimeInterval] = [:]
        for tool in [MediaTool.ytdlp, .ffmpeg] {
            if let remaining = installer.backoffRemaining(tool) { backoff[tool] = remaining }
        }
        self.backoff = backoff
    }

    /// "Update now": downloads the latest yt-dlp over Osprey's own copy. Nil when busy or backed off.
    @discardableResult
    public func updateYtDlp() -> Task<Void, Never>? {
        run(.ytdlp) { [installer] report in try await installer.updateYtDlp(report) }
    }

    /// "Install": puts Osprey's own copy of `tool` in place (a missing ffmpeg, or yt-dlp when only Homebrew's
    /// is there). A failure is reported even when another copy remains usable. Nil when busy or backed off.
    @discardableResult
    public func install(_ tool: MediaTool) -> Task<Void, Never>? {
        run(tool) { [installer] report in try await installer.installManaged(tool, report) }
    }

    private func run(_ tool: MediaTool,
                     _ operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> ToolLocation) -> Task<Void, Never>? {
        guard progress[tool] == nil else { return nil }
        // Ask the installer, not the last look: the countdown may have started since.
        if let remaining = installer.backoffRemaining(tool) {
            backoff[tool] = remaining
            return nil
        }
        let id = UUID()
        runs[tool] = id
        progress[tool] = .some(nil)
        errors[tool] = nil
        return Task {
            do {
                let location = try await operation { fraction in
                    Task { @MainActor in self.report(fraction, for: tool, run: id) }
                }
                if location.source != .managed { errors[tool] = Self.fallbackMessage(tool) }
            } catch is CancellationError {
            } catch {
                errors[tool] = Self.failureMessage(tool, error)
            }
            runs[tool] = nil
            progress[tool] = nil
            await reload()
        }
    }

    /// Progress from run `id`: dropped once that run has ended or been replaced, and never lower than before
    /// (reports hop to the main actor in separate tasks and can arrive out of order).
    func report(_ fraction: Double, for tool: MediaTool, run id: UUID) {
        guard runs[tool] == id, let current = progress[tool] else { return }
        progress[tool] = .some(max(current ?? 0, min(max(fraction, 0), 1)))
    }

    func currentRun(_ tool: MediaTool) -> UUID? { runs[tool] }

    static func fallbackMessage(_ tool: MediaTool) -> String {
        "Couldn't download \(tool.fileName). Using Homebrew's copy for now."
    }

    static func failureMessage(_ tool: MediaTool, _ error: any Error) -> String {
        if case .installFailed(let detail) = error as? MediaError { return "Couldn't download \(tool.fileName) (\(detail))." }
        return "Couldn't download \(tool.fileName). Check your internet connection and try again."
    }

    /// "2026.10.10" from yt-dlp; "8.0.1" from "ffmpeg version 8.0.1 Copyright (c) …".
    public nonisolated static func shortVersion(_ line: String?) -> String? {
        guard let line else { return nil }
        let words = line.split(separator: " ")
        if words.count >= 3, words[0] == "ffmpeg", words[1] == "version" { return String(words[2]) }
        return words.first.map(String.init)
    }
}
