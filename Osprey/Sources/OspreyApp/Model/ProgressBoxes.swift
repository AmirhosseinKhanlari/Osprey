import OspreyEngine

/// One box of the design's segmented progress bar.
struct ProgressBox: Equatable {
    /// How much of the box's bytes are on disk, 0…1.
    var fraction: Double
    /// A connection working in this box has stopped receiving.
    var stalled: Bool
}

enum ProgressBoxes {
    /// Splits the file into `count` equal byte ranges, one per connection lane, and fills each by
    /// the bytes already received inside it. A box holding a stalled lane's next byte is marked.
    static func make(_ snapshot: DownloadSnapshot, count: Int, completed: Bool) -> [ProgressBox] {
        let count = max(1, count)
        if completed { return Array(repeating: ProgressBox(fraction: 1, stalled: false), count: count) }
        guard let total = snapshot.totalSize, total > 0 else {
            return Array(repeating: ProgressBox(fraction: 0, stalled: false), count: count)
        }
        let size = Double(total) / Double(count)
        var filled = Array(repeating: 0.0, count: count)
        for segment in snapshot.segments where segment.received > 0 {
            let start = Double(segment.start)
            let end = Double(segment.start + min(segment.received, segment.length))
            var index = max(0, min(count - 1, Int(start / size)))
            while index < count {
                let lower = Double(index) * size
                let upper = lower + size
                if lower >= end { break }
                filled[index] += max(0, min(end, upper) - max(start, lower))
                index += 1
            }
        }
        var stalled = Array(repeating: false, count: count)
        for lane in snapshot.lanes where lane.phase == .stalled {
            guard let segment = snapshot.segments.first(where: { $0.id == lane.segmentID }) else { continue }
            stalled[max(0, min(count - 1, Int(Double(segment.next) / size)))] = true
        }
        return (0..<count).map { ProgressBox(fraction: min(1, filled[$0] / size), stalled: stalled[$0]) }
    }
}
