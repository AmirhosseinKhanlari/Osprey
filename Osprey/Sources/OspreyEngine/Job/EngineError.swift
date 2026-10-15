import Foundation

public enum EngineError: Error, Sendable, Equatable, LocalizedError {
    case notHTTP
    case unknownSize
    case rangeNotHonored
    case remoteFileChanged
    case timedOut
    case emptyResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case writeFailed(String)

    /// Fatal errors stop the whole download instead of backing off.
    public var isFatal: Bool {
        switch self {
        case .httpStatus(let code, _): return [400, 401, 403, 404, 405, 410, 416].contains(code)
        case .timedOut, .emptyResponse: return false
        default: return true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notHTTP: return "The address did not return an HTTP response."
        case .unknownSize: return "The server did not report the file size."
        case .rangeNotHonored: return "The server stopped honouring byte ranges."
        case .remoteFileChanged: return "The file changed on the server since the download started."
        case .timedOut: return "The server stopped responding."
        case .emptyResponse: return "The server closed the connection without sending data."
        case .httpStatus(let code, _): return "The server answered HTTP \(code)."
        case .writeFailed(let reason): return "Could not write to disk: \(reason)"
        }
    }
}
