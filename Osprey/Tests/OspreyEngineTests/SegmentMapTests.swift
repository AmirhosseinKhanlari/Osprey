import Foundation
import Testing
@testable import OspreyEngine

@Suite struct SegmentMapTests {
    @Test func newMapIsOneUnownedSegment() {
        var map = SegmentMap(totalSize: 100)
        #expect(map.segments == [Segment(id: 0, start: 0, end: 99)])
        #expect(map.nextAssignment(owned: [], minPiece: 10) == 0)
        #expect(map.segments.count == 1)
    }

    @Test func splitHalvesTheLargestOwnedRemainder() {
        var map = SegmentMap(totalSize: 100)
        let id = map.nextAssignment(owned: [0], minPiece: 10)
        #expect(id == 1)
        #expect(map.segments == [Segment(id: 0, start: 0, end: 49), Segment(id: 1, start: 50, end: 99)])
    }

    @Test func splitUsesRemainingBytesNotLength() {
        var map = SegmentMap(totalSize: 100)
        _ = map.nextAssignment(owned: [0], minPiece: 10)          // 0…49, 50…99
        map.record(30, for: 0)                                    // seg 0 next = 30, remaining 20
        let id = map.nextAssignment(owned: [0, 1], minPiece: 1)   // largest remaining is seg 1 (50)
        #expect(id == 2)
        #expect(map.segment(id: 1) == Segment(id: 1, start: 50, end: 74))
        #expect(map.segment(id: 2) == Segment(id: 2, start: 75, end: 99))
    }

    @Test func neverSplitsBelowTheFloor() {
        #expect(SegmentMap.splitFloor(minPiece: 10) == 23)
        var map = SegmentMap(totalSize: 40)
        #expect(map.nextAssignment(owned: [0], minPiece: 10) == 1)   // 40 ≥ 23 → 20 + 20
        #expect(map.nextAssignment(owned: [0, 1], minPiece: 10) == nil)
    }

    @Test func unownedUnfinishedSegmentsComeFirst() {
        var map = SegmentMap(totalSize: 100)
        _ = map.nextAssignment(owned: [0], minPiece: 10)
        #expect(map.nextAssignment(owned: [0], minPiece: 10) == 1)
        #expect(map.segments.count == 2)
    }

    @Test func recordClampsToRemainingAndTracksCompletion() {
        var map = SegmentMap(totalSize: 100)
        _ = map.nextAssignment(owned: [0], minPiece: 10)
        #expect(map.record(70, for: 0) == 50)
        #expect(map.segment(id: 0)?.isComplete == true)
        #expect(map.downloaded == 50)
        #expect(map.isComplete == false)
        #expect(map.record(50, for: 1) == 50)
        #expect(map.isComplete)
    }

    @Test func successorIsTheNextRangeByOffset() {
        var map = SegmentMap(totalSize: 100)
        _ = map.nextAssignment(owned: [0], minPiece: 10)
        #expect(map.successor(of: 0)?.id == 1)
        #expect(map.successor(of: 1) == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        var map = SegmentMap(totalSize: 1_000)
        _ = map.nextAssignment(owned: [0], minPiece: 10)
        map.record(123, for: 1)
        let decoded = try JSONDecoder().decode(SegmentMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        var again = decoded
        #expect(again.nextAssignment(owned: [0, 1], minPiece: 10) == 2)
    }
}
