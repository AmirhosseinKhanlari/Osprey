import Foundation

public enum BridgeProtocol {
    public static let version = 1
    public static let maxMessageBytes = 1_048_576
}

/// What the extensions need to decide on their own which downloads to offer.
public struct CaptureRules: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var extensions: [String]
    public var captureInPrivate: Bool
    /// Whether extensions show the floating "download this video" button.
    public var videoButton: Bool

    public init(enabled: Bool, extensions: [String], captureInPrivate: Bool, videoButton: Bool = true) {
        self.enabled = enabled
        self.extensions = extensions
        self.captureInPrivate = captureInPrivate
        self.videoButton = videoButton
    }

    private enum CodingKeys: String, CodingKey { case enabled, extensions, captureInPrivate, videoButton }

    /// `videoButton` is missing from older rules JSON and then defaults to true.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        extensions = try c.decode([String].self, forKey: .extensions)
        captureInPrivate = try c.decode(Bool.self, forKey: .captureInPrivate)
        videoButton = try c.decodeIfPresent(Bool.self, forKey: .videoButton) ?? true
    }
}

public struct BridgeRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case hello, capture, media }
    public enum Source: String, Codable, Sendable { case auto, menu, button }

    public var v: Int
    public var type: Kind
    public var url: String?
    public var referrer: String?
    public var filename: String?
    public var mime: String?
    public var size: Int64?
    public var cookies: String?
    public var userAgent: String?
    public var title: String?
    public var isPrivate: Bool?
    public var source: Source?

    enum CodingKeys: String, CodingKey {
        case v, type, url, referrer, filename, mime, size, cookies, userAgent, source, title
        case isPrivate = "private"
    }

    public static func hello() -> BridgeRequest {
        BridgeRequest(v: BridgeProtocol.version, type: .hello)
    }

    public static func capture(url: String, referrer: String? = nil, filename: String? = nil, mime: String? = nil,
                               size: Int64? = nil, cookies: String? = nil, userAgent: String? = nil,
                               isPrivate: Bool = false, source: Source = .auto) -> BridgeRequest {
        BridgeRequest(v: BridgeProtocol.version, type: .capture, url: url, referrer: referrer, filename: filename,
                      mime: mime, size: size, cookies: cookies, userAgent: userAgent, isPrivate: isPrivate, source: source)
    }

    /// Asks the app to open its video picker for a page.
    public static func media(url: String, title: String? = nil, cookies: String? = nil,
                             isPrivate: Bool = false, source: Source = .button) -> BridgeRequest {
        BridgeRequest(v: BridgeProtocol.version, type: .media, url: url, cookies: cookies, title: title,
                      isPrivate: isPrivate, source: source)
    }
}

public struct BridgeResponse: Codable, Sendable, Equatable {
    public enum ErrorCode: String, Codable, Sendable {
        case unsupportedVersion = "unsupported-version"
        case badRequest = "bad-request"
        case disabled
        case internalError = "internal"
        case unavailable
        case notRunning = "not-running"
    }

    public var v: Int
    public var ok: Bool
    public var version: String?
    public var rules: CaptureRules?
    public var taken: Bool?
    public var reason: String?
    public var error: ErrorCode?

    public static func hello(version: String, rules: CaptureRules) -> BridgeResponse {
        BridgeResponse(v: BridgeProtocol.version, ok: true, version: version, rules: rules)
    }

    public static func capture(taken: Bool, reason: String? = nil) -> BridgeResponse {
        BridgeResponse(v: BridgeProtocol.version, ok: true, taken: taken, reason: reason)
    }

    public static func failure(_ code: ErrorCode) -> BridgeResponse {
        BridgeResponse(v: BridgeProtocol.version, ok: false, error: code)
    }

    /// True only for a successful capture reply that took the download.
    public var wasTaken: Bool { ok && taken == true }
}
