import Foundation

/// Everything needed to continue a download after pause, crash or relaunch.
/// Stored as JSON next to the `.slpart` file.
public struct ResumeState: Sendable, Codable, Equatable {
    /// Where the bytes come from: the probe's final URL after redirects. It can expire (signed CDN links).
    public var url: URL
    /// The address the user gave. It is probed again on resume, and when `url` stops working, to get a fresh `url`.
    public var originalURL: URL
    public var destination: URL
    public var headers: [String: String]
    public var totalSize: Int64
    public var etag: String?
    public var lastModified: String?
    public var acceptsRanges: Bool
    public var map: SegmentMap

    public init(url: URL, destination: URL, headers: [String: String], totalSize: Int64,
                etag: String?, lastModified: String?, acceptsRanges: Bool, map: SegmentMap, originalURL: URL? = nil) {
        self.url = url
        self.originalURL = originalURL ?? url
        self.destination = destination
        self.headers = headers
        self.totalSize = totalSize
        self.etag = etag
        self.lastModified = lastModified
        self.acceptsRanges = acceptsRanges
        self.map = map
    }

    private enum CodingKeys: String, CodingKey {
        case url, originalURL, destination, headers, totalSize, etag, lastModified, acceptsRanges, map
    }

    /// Sidecars written before `originalURL` existed decode with `originalURL == url`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        originalURL = try container.decodeIfPresent(URL.self, forKey: .originalURL) ?? url
        destination = try container.decode(URL.self, forKey: .destination)
        headers = try container.decode([String: String].self, forKey: .headers)
        totalSize = try container.decode(Int64.self, forKey: .totalSize)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        acceptsRanges = try container.decode(Bool.self, forKey: .acceptsRanges)
        map = try container.decode(SegmentMap.self, forKey: .map)
    }

    public var partURL: URL { destination.appendingPathExtension("slpart") }
    public var stateURL: URL { partURL.appendingPathExtension("json") }
}

public enum ResumeStore {
    public static func save(_ state: ResumeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var stored = state
        stored.headers = HTTPHeaders.withoutSensitive(state.headers)   // never persist credentials
        let url = stored.stateURL
        try encoder.encode(stored).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    public static func load(from url: URL) throws -> ResumeState {
        try JSONDecoder().decode(ResumeState.self, from: Data(contentsOf: url))
    }
}
