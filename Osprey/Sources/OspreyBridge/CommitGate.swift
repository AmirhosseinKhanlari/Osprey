import Foundation

/// Decides, once per request, whether the app's answer still counts.
///
/// The server gives a handler a limited time. When that runs out it replies `internal`, and the
/// browser keeps (resumes) its own download. A handler that is still running must then not add the
/// download as well, or the user gets it twice. So before acting, the handler calls `tryCommit()`;
/// on timeout the server calls `expire()`. Whichever comes first wins:
/// - commit first: the server waits for the handler's real reply instead of answering `internal`;
/// - expire first: `tryCommit()` returns false and the handler must not act.
public final class CommitGate: @unchecked Sendable {
    private enum State { case pending, committed, expired }

    private let lock = NSLock()
    private var state = State.pending

    public init() {}

    /// True when the handler may act: the request hasn't expired. Calling it again after a commit is harmless.
    public func tryCommit() -> Bool {
        lock.withLock {
            switch state {
            case .pending: state = .committed; return true
            case .committed: return true
            case .expired: return false
            }
        }
    }

    /// Marks the request as answered without the handler. False when the handler had already committed.
    @discardableResult
    public func expire() -> Bool {
        lock.withLock {
            switch state {
            case .pending: state = .expired; return true
            case .committed: return false
            case .expired: return true
            }
        }
    }

    public var isExpired: Bool { lock.withLock { state == .expired } }
}
