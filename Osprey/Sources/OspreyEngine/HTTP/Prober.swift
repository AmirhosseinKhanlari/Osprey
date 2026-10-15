import Foundation

public struct ProbeResult: Sendable, Equatable {
    public var finalURL: URL
    public var totalSize: Int64?
    public var acceptsRanges: Bool
    public var etag: String?
    public var lastModified: String?
    public var suggestedFilename: String
    public var contentType: String?
}

/// Asks for byte 0 only: a 206 proves ranges work and gives the total size in Content-Range.
public enum Prober {
    public static func probe(_ request: URLRequest, session: URLSession) async throws -> ProbeResult {
        var request = request
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request, delegate: CredentialGuardDelegate())
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw EngineError.notHTTP }
        let status = http.statusCode
        let totalSize: Int64?
        let acceptsRanges: Bool
        switch status {
        case 206:
            totalSize = HTTPHeaders.totalSize(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            acceptsRanges = true
        case 200..<300:
            totalSize = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            acceptsRanges = false
        default:
            throw EngineError.httpStatus(status, retryAfter: HTTPHeaders.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        let finalURL = http.url ?? request.url!
        let name = ContentDisposition.filename(from: http.value(forHTTPHeaderField: "Content-Disposition"))
            ?? FileNaming.name(from: finalURL)
        return ProbeResult(finalURL: finalURL, totalSize: totalSize, acceptsRanges: acceptsRanges,
                           etag: http.value(forHTTPHeaderField: "ETag"),
                           lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                           suggestedFilename: name,
                           contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }
}
