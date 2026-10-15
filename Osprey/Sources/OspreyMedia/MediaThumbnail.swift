import Foundation

/// Loads a video's thumbnail for the picker. A private window's request uses an ephemeral session, so the image
/// (and the address it came from) never reaches the shared URL cache on disk, as `AsyncImage` would put it.
public enum MediaThumbnail {
    public static func configuration(isPrivate: Bool) -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration = isPrivate ? .ephemeral : .default
        if isPrivate {
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
        }
        configuration.timeoutIntervalForRequest = 20
        return configuration
    }

    /// The image bytes, or nil for a non-web address, an error status or a failure. At most 10 MB.
    public static func load(_ url: URL, isPrivate: Bool) async -> Data? {
        guard MediaURL.isWebURL(url) else { return nil }
        let session = URLSession(configuration: configuration(isPrivate: isPrivate))
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 10_000_000
        else { return nil }
        return data
    }
}
