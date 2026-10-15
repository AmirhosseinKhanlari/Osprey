import Foundation
import OspreyBridge

/// A validated download handed over by a browser.
public struct CaptureOrder: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public var preferredFilename: String?
    public var source: BridgeRequest.Source
    public var isPrivate: Bool
}

/// A browser's request to open the video picker for a page.
public struct MediaOrder: Sendable, Equatable {
    public var pageURL: URL
    public var title: String?
    public var cookieHeader: String?
    public var isPrivate: Bool
    public var source: BridgeRequest.Source

    public init(pageURL: URL, title: String?, cookieHeader: String?, isPrivate: Bool, source: BridgeRequest.Source) {
        self.pageURL = pageURL
        self.title = title
        self.cookieHeader = cookieHeader
        self.isPrivate = isPrivate
        self.source = source
    }
}

/// Applies the integration settings to bridge requests and turns accepted captures into orders.
public struct CaptureRouter: Sendable {
    /// Adds the download. It must win `gate.tryCommit()` right before adding anything and return false when
    /// it loses: the server already answered `internal`, so the browser is keeping the file itself.
    public typealias Accept = @Sendable (CaptureOrder, CommitGate) async -> Bool

    private let appVersion: String
    private let settings: @Sendable () -> IntegrationSettings
    /// Opens the video picker. The router wins the commit gate before calling it, so it never runs for a request
    /// the server already answered as timed out.
    public typealias AcceptMedia = @Sendable (MediaOrder) async -> Bool

    private let accept: Accept
    private let acceptMedia: AcceptMedia

    public init(appVersion: String, settings: @escaping @Sendable () -> IntegrationSettings,
                acceptMedia: @escaping AcceptMedia = { _ in false }, accept: @escaping Accept) {
        self.appVersion = appVersion
        self.settings = settings
        self.acceptMedia = acceptMedia
        self.accept = accept
    }

    /// `gate` is the server's commit gate for this request (a fresh one when the caller has no deadline).
    public func handle(_ request: BridgeRequest, gate: CommitGate = CommitGate()) async -> BridgeResponse {
        let current = settings()
        switch request.type {
        case .hello:
            return .hello(version: appVersion, rules: current.rules)
        case .capture:
            guard current.enabled else { return .failure(.disabled) }
            guard let raw = request.url, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil else {
                return .capture(taken: false, reason: "unsupported-url")
            }
            let isPrivate = request.isPrivate ?? false
            if isPrivate && !current.captureInPrivate { return .capture(taken: false, reason: "private") }
            var headers: [String: String] = [:]
            Self.set("Referer", request.referrer, in: &headers)
            Self.set("Cookie", request.cookies, in: &headers)
            Self.set("User-Agent", request.userAgent, in: &headers)
            let name = request.filename
                .flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { candidate -> String? in
                    candidate.isEmpty || candidate == "." || candidate == ".." ? nil : candidate
                }
            let order = CaptureOrder(url: url, headers: headers, preferredFilename: name,
                                     source: request.source ?? .auto, isPrivate: isPrivate)
            // Already timed out: the browser has resumed its own download, so don't even ask.
            guard !gate.isExpired else { return .capture(taken: false, reason: "expired") }
            return await accept(order, gate) ? .capture(taken: true) : .capture(taken: false, reason: "rejected")
        case .media:
            guard current.enabled else { return .failure(.disabled) }
            guard let raw = request.url, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil else {
                return .capture(taken: false, reason: "unsupported-url")
            }
            let isPrivate = request.isPrivate ?? false
            if isPrivate && !current.captureInPrivate { return .capture(taken: false, reason: "private") }
            var headers: [String: String] = [:]
            Self.set("Cookie", request.cookies, in: &headers)
            let title = request.title.map { String($0.unicodeScalars.filter { !Self.isControl($0) }.map(Character.init)) }
                .map { String($0.prefix(300)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let order = MediaOrder(pageURL: url, title: title, cookieHeader: headers["Cookie"], isPrivate: isPrivate,
                                   source: request.source ?? .button)
            guard !gate.isExpired, gate.tryCommit() else { return .capture(taken: false, reason: "expired") }
            return await acceptMedia(order) ? .capture(taken: true) : .capture(taken: false, reason: "rejected")
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        return code < 0x20 || code == 0x7F || (0x80...0x9F).contains(code) || code == 0x2028 || code == 0x2029
    }

    /// Header values must not smuggle extra header lines or other control characters.
    /// Rejects any value containing a control character (U+0000-U+001F except tab, and U+007F),
    /// or a Unicode newline (U+000A-U+000D, U+0085, U+2028, U+2029). Checked per scalar, because
    /// "\r\n" is a single Character and would slip past a per-"\r" or per-"\n" check.
    private static func set(_ field: String, _ value: String?, in headers: inout [String: String]) {
        guard let value, !value.isEmpty, !value.unicodeScalars.contains(where: isUnsafeHeaderScalar) else { return }
        headers[field] = value
    }

    private static func isUnsafeHeaderScalar(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        if code < 0x20 { return code != 0x09 }
        if code == 0x7F { return true }
        return code == 0x85 || code == 0x2028 || code == 0x2029
    }
}
