import Foundation

public enum DownloadState: Sendable, Equatable {
    case idle, probing, downloading, finishing, paused, completed
    case failed(String)
}

public enum LanePhase: Sendable, Equatable {
    case connecting, receiving, stalled
}

public struct LaneSnapshot: Sendable, Equatable, Identifiable {
    public let id: Int
    public var segmentID: Int?
    public var phase: LanePhase
    public var bytesPerSecond: Double

    public init(id: Int, segmentID: Int?, phase: LanePhase, bytesPerSecond: Double) {
        self.id = id
        self.segmentID = segmentID
        self.phase = phase
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct DownloadSnapshot: Sendable, Equatable {
    public var state: DownloadState
    public var fileName: String
    public var totalSize: Int64?
    public var downloaded: Int64
    public var bytesPerSecond: Double
    public var segments: [Segment]
    public var lanes: [LaneSnapshot]
    public var acceptsRanges: Bool
    public var etag: String?
    public var lastModified: String?
    public var destination: URL?

    public init(state: DownloadState, fileName: String, totalSize: Int64?, downloaded: Int64, bytesPerSecond: Double,
                segments: [Segment], lanes: [LaneSnapshot], acceptsRanges: Bool, etag: String?, destination: URL?,
                lastModified: String? = nil) {
        self.state = state
        self.fileName = fileName
        self.totalSize = totalSize
        self.downloaded = downloaded
        self.bytesPerSecond = bytesPerSecond
        self.segments = segments
        self.lanes = lanes
        self.acceptsRanges = acceptsRanges
        self.etag = etag
        self.lastModified = lastModified
        self.destination = destination
    }

    public static func placeholder(fileName: String) -> DownloadSnapshot {
        DownloadSnapshot(state: .idle, fileName: fileName, totalSize: nil, downloaded: 0, bytesPerSecond: 0,
                         segments: [], lanes: [], acceptsRanges: false, etag: nil, destination: nil)
    }
}
