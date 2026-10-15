/// The file's byte ranges, ordered by offset.
public struct SegmentMap: Sendable, Codable, Equatable {
    public private(set) var totalSize: Int64
    public private(set) var segments: [Segment]
    private var nextID: Int

    public init(totalSize: Int64) {
        precondition(totalSize > 0, "SegmentMap needs a known, positive size")
        self.totalSize = totalSize
        self.segments = [Segment(id: 0, start: 0, end: totalSize - 1)]
        self.nextID = 1
    }

    public var downloaded: Int64 { segments.reduce(0) { $0 + min($1.received, $1.length) } }
    public var isComplete: Bool { segments.allSatisfy(\.isComplete) }

    public func segment(id: Int) -> Segment? { segments.first { $0.id == id } }

    /// The range that starts right after `id` ends.
    public func successor(of id: Int) -> Segment? {
        guard let index = segments.firstIndex(where: { $0.id == id }), index + 1 < segments.count else { return nil }
        return segments[index + 1]
    }

    /// A range whose remaining bytes are below `2·minPiece + 3` is never split.
    public static func splitFloor(minPiece: Int64) -> Int64 { 2 * minPiece + 3 }

    /// Records `count` new bytes for segment `id`; returns how many fit (clamped to what remains).
    @discardableResult
    public mutating func record(_ count: Int64, for id: Int) -> Int64 {
        guard count > 0, let index = segments.firstIndex(where: { $0.id == id }) else { return 0 }
        let accepted = min(count, segments[index].remaining)
        segments[index].received += accepted
        return accepted
    }

    /// Work for a free connection.
    /// 1. An unfinished segment nobody owns (after resume, failure or takeover).
    /// 2. Otherwise halve the owned segment with the most bytes left. The new segment is the upper half.
    public mutating func nextAssignment(owned: Set<Int>, minPiece: Int64) -> Int? {
        if let free = segments.first(where: { !$0.isComplete && !owned.contains($0.id) }) {
            return free.id
        }
        let candidates = segments.indices.filter { owned.contains(segments[$0].id) && !segments[$0].isComplete }
        guard let victimIndex = candidates.max(by: { segments[$0].remaining < segments[$1].remaining }) else { return nil }
        let victim = segments[victimIndex]
        guard victim.remaining >= Self.splitFloor(minPiece: minPiece) else { return nil }
        let half = victim.remaining / 2
        let newStart = victim.end - half + 1
        let created = Segment(id: nextID, start: newStart, end: victim.end)
        nextID += 1
        segments[victimIndex].end = newStart - 1
        segments.insert(created, at: victimIndex + 1)
        return created.id
    }
}
