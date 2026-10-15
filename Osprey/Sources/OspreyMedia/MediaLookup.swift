import Foundation

/// What a lookup reports while it runs.
public enum LookupProgress: Sendable, Equatable {
    /// Installing the managed yt-dlp; the fraction once known.
    case installing(Double?)
    /// The install returned and the page is being read again.
    case extracting
}

/// Looks pages up with Osprey's own yt-dlp. The managed copy is installed on first use; a Homebrew copy is used
/// only when that install fails, and if it then can't read a page, the managed install is tried again once.
public struct MediaLookup: Sendable {
    private let tools: MediaTools
    private let installer: ToolInstaller
    private let extractor: MediaExtractor

    public init(tools: MediaTools, installer: ToolInstaller, extractor: MediaExtractor) {
        self.tools = tools
        self.installer = installer
        self.extractor = extractor
    }

    /// True when `prepare` will download the managed yt-dlp: it's missing, and no backed-off install is falling
    /// back to another copy (then there's nothing to set up, so no "Setting up…" flash).
    public var needsSetup: Bool {
        guard let found = tools.locate(.ytdlp) else { return true }
        return found.source != .managed && !installer.isInstallBackedOff(.ytdlp)
    }

    /// Installs the managed yt-dlp when missing (progress 0…1). Falls back to Homebrew when the install fails.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await installer.ensureManaged(.ytdlp, progress: progress)
    }

    /// Looks a page up the way the picker does: flat, unless the URL names one video inside a list
    /// (see `MediaURL.namesVideoInList`). The result's `_type` decides playlist or single.
    ///
    /// A flat answer that can't be shown as is gets one more lookup, alone (`--no-playlist`): a single without formats
    /// is read again, and a one-entry list becomes its entry. Anything else is returned unchanged.
    public func probe(_ url: URL, cookieHeader: String?,
                      progress: @escaping @Sendable (LookupProgress) -> Void) async throws -> MediaProbeResult {
        let flat = !MediaURL.namesVideoInList(url)
        let result = try await probe(url, cookieHeader: cookieHeader, playlist: flat, progress: progress)
        guard flat else { return result }
        switch result {
        case .single(let info) where info.formats.isEmpty:
            try Task.checkCancellation()
            return try await probe(url, cookieHeader: cookieHeader, playlist: false, progress: progress)
        case .playlist(let list) where list.entries.count == 1:
            try Task.checkCancellation()
            let entry = list.entries[0].url
            let cookie = MediaURL.cookieHeader(cookieHeader, from: url, for: entry)
            return try await probe(entry, cookieHeader: cookie, playlist: false, progress: progress)
        default:
            return result
        }
    }

    /// Probes the page. When a non-managed yt-dlp fails to extract (a stale copy can't read the site any more), installs
    /// the managed one and retries once, reporting `.installing` and then `.extracting`. Not inside the install backoff.
    public func probe(_ url: URL, cookieHeader: String?, playlist: Bool,
                      progress: @escaping @Sendable (LookupProgress) -> Void) async throws -> MediaProbeResult {
        let managed = tools.locate(.ytdlp)?.source == .managed
        do {
            return try await extractor.probe(url, cookieHeader: cookieHeader, playlist: playlist)
        } catch let error as MediaError where !managed && Self.mayBeStaleTool(error) {
            guard !installer.isInstallBackedOff(.ytdlp) else { throw error }
            progress(.installing(nil))
            guard let installed = try? await installer.installManaged(.ytdlp, progress: { progress(.installing($0)) }),
                  installed.source == .managed else { throw error }
            try Task.checkCancellation()
            progress(.extracting)
            return try await extractor.probe(url, cookieHeader: cookieHeader, playlist: playlist)
        }
    }

    private static func mayBeStaleTool(_ error: MediaError) -> Bool {
        switch error {
        case .unsupported, .extractionFailed: true
        default: false
        }
    }
}
