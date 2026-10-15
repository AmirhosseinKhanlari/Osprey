/// One byte range of the remote file and how much of it has been written.
/// `end` is inclusive. `received` counts bytes from `start`.
public struct Segment: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public var start: Int64
    public var end: Int64
    public var received: Int64

    public init(id: Int, start: Int64, end: Int64, received: Int64 = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.received = received
    }

    /// Absolute offset of the next byte to fetch.
    public var next: Int64 { start + received }
    public var length: Int64 { end - start + 1 }
    public var remaining: Int64 { max(0, end - next + 1) }
    public var isComplete: Bool { remaining == 0 }
}
