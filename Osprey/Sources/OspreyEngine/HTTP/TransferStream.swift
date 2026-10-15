import Foundation

public enum TransferEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// A URLSession data task delivered as an async stream of chunks.
/// Ending iteration early cancels the task.
public enum TransferStream {
    public static func events(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<TransferEvent, Error> {
        open(request, session: session, bufferCap: .max).events   // no consumer accounting here
    }

    /// Like `events(for:session:)`, plus flow control: the consumer reports what it has consumed and can
    /// suspend the underlying task. The task is also suspended while more than `bufferCap` bytes are
    /// waiting to be consumed, so a slow disk or a throttled lane stops reading from the socket.
    public static func open(_ request: URLRequest, session: URLSession, bufferCap: Int = 8 << 20) -> TransferHandle {
        let control = TransferControl(bufferCap: bufferCap)
        let events = AsyncThrowingStream<TransferEvent, Error> { continuation in
            let task = session.dataTask(with: request)
            control.attach(task)
            task.delegate = StreamingDelegate(continuation: continuation, control: control)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
        return TransferHandle(events: events, control: control)
    }
}

/// The event stream plus the controls for the task behind it.
public struct TransferHandle: Sendable {
    public let events: AsyncThrowingStream<TransferEvent, Error>
    let control: TransferControl

    /// Reports that `count` bytes delivered by `.data` have been processed (written or dropped).
    public func consumed(_ count: Int) { control.consumed(count) }

    /// Stops reading from the socket until `resumeReading()` (the limiter's pause).
    public func suspendReading() { control.setThrottled(true) }
    public func resumeReading() { control.setThrottled(false) }

    /// Changes the unconsumed-bytes cap (a limited download keeps it small so the socket, not RAM, absorbs the excess).
    public func setBufferCap(_ bytes: Int) { control.setBufferCap(bytes) }

    /// Bytes delivered but not yet reported as consumed.
    public var buffered: Int { control.bufferedBytes }
}

/// Suspends the task while either the limiter wants it paused or the unconsumed buffer is over its cap.
final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCap: Int
    private var task: URLSessionDataTask?
    private var buffered = 0
    private var throttled = false
    private var overfull = false
    private var suspended = false

    init(bufferCap: Int) { self.bufferCap = max(1, bufferCap) }

    var bufferedBytes: Int { lock.withLock { buffered } }

    func attach(_ task: URLSessionDataTask) { lock.withLock { self.task = task } }

    func produced(_ count: Int) {
        lock.withLock {
            buffered += count
            if buffered > bufferCap { overfull = true }
            applyLocked()
        }
    }

    func consumed(_ count: Int) {
        lock.withLock {
            buffered = max(0, buffered - count)
            if overfull, buffered <= bufferCap / 2 { overfull = false }
            applyLocked()
        }
    }

    func setBufferCap(_ bytes: Int) {
        lock.withLock {
            bufferCap = max(1, bytes)
            if buffered > bufferCap { overfull = true } else if overfull, buffered <= bufferCap / 2 { overfull = false }
            applyLocked()
        }
    }

    func setThrottled(_ value: Bool) {
        lock.withLock {
            throttled = value
            applyLocked()
        }
    }

    private func applyLocked() {
        let wanted = throttled || overfull
        guard wanted != suspended, let task, task.state == .running || task.state == .suspended else { return }
        suspended = wanted
        if wanted { task.suspend() } else { task.resume() }
    }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let continuation: AsyncThrowingStream<TransferEvent, Error>.Continuation
    let control: TransferControl

    init(continuation: AsyncThrowingStream<TransferEvent, Error>.Continuation, control: TransferControl) {
        self.continuation = continuation
        self.control = control
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        HTTPHeaders.redirected(request, from: response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: EngineError.notHTTP)
            return .cancel
        }
        continuation.yield(.response(http))
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        control.produced(data.count)
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error)
    }
}
