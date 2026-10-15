import Foundation

/// Task delegate that drops credentials when a redirect leaves the origin.
final class CredentialGuardDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        HTTPHeaders.redirected(request, from: response)
    }
}

public enum HTTPHeaders {
    /// Credentials that must never reach disk or another host.
    public static func isSensitive(_ field: String) -> Bool {
        ["cookie", "authorization"].contains(field.lowercased())
    }

    /// The headers without credentials (what the resume sidecar may store).
    public static func withoutSensitive(_ headers: [String: String]) -> [String: String] {
        headers.filter { !isSensitive($0.key) }
    }

    /// What the resume sidecar may store. A private download also leaves out the Referer.
    public static func persistable(_ headers: [String: String], isPrivate: Bool) -> [String: String] {
        withoutSensitive(headers).filter { !isPrivate || $0.key.lowercased() != "referer" }
    }

    /// True when credentials given for `original` may be sent to `target`: the same host and port (default
    /// ports normalized) over the same scheme, or an upgrade from http to https on default ports.
    /// They never go from https to http, where anyone on the path could read them.
    public static func mayCarryCredentials(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
              let fromScheme = original.scheme?.lowercased(), let toScheme = target.scheme?.lowercased(),
              let fromHost = original.host?.lowercased(), let toHost = target.host?.lowercased(), fromHost == toHost,
              let fromPort = effectivePort(original, scheme: fromScheme), let toPort = effectivePort(target, scheme: toScheme)
        else { return false }
        if fromScheme == toScheme { return fromPort == toPort }
        return fromScheme == "http" && toScheme == "https" && fromPort == 80 && toPort == 443
    }

    /// The URL's port, or its scheme's default; nil for schemes that never carry our credentials.
    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        switch scheme {
        case "http": url.port ?? 80
        case "https": url.port ?? 443
        default: nil
        }
    }

    /// The redirect request without credentials when it leaves the response's origin.
    public static func redirected(_ request: URLRequest, from response: HTTPURLResponse) -> URLRequest {
        guard !mayCarryCredentials(from: response.url, to: request.url) else { return request }
        var request = request
        for field in request.allHTTPHeaderFields?.keys ?? [:].keys where isSensitive(field) {
            request.setValue(nil, forHTTPHeaderField: field)
        }
        return request
    }

    /// `bytes a-b/TOTAL` → TOTAL (nil for `*` or malformed).
    public static func totalSize(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// `bytes a-b/TOTAL` → a.
    public static func rangeStart(fromContentRange value: String?) -> Int64? {
        guard let value, let space = value.firstIndex(of: " "), let dash = value.firstIndex(of: "-"), space < dash else { return nil }
        return Int64(value[value.index(after: space)..<dash])
    }

    /// The last byte of `Content-Range: bytes <start>-<end>/<total>`; nil for `bytes */<total>` or a malformed value.
    public static func rangeEnd(fromContentRange value: String?) -> Int64? {
        guard let value, let dash = value.firstIndex(of: "-") else { return nil }
        let rest = value[value.index(after: dash)...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return Int64(rest[..<slash])
    }

    /// `Retry-After` as delta-seconds or HTTP-date.
    public static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        // Delta-seconds: 1-10 ASCII digits only (rejects "inf", "nan", "1e308", "0x10", "-5").
        if value.count <= 10, value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int(value) {
            return TimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
