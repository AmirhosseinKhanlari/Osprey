import Foundation
import Testing
import OspreyEngine
@testable import OspreyLibrary

@Suite struct DownloadRecordTests {
    @Test func recordsRoundTripThroughJSON() throws {
        let records = [fileRecord(state: .failed("The server answered HTTP 500.")),
                       mediaDownloadRecord(state: .completed),
                       fileRecord(state: .completed)]
        let data = try JSONEncoder().encode(records)
        #expect(try JSONDecoder().decode([DownloadRecord].self, from: data) == records)
    }

    @Test func aRunningDownloadIsSavedPausedAndKeepsNoCredentials() {
        for running in [DownloadState.idle, .probing, .downloading, .finishing, .paused] {
            #expect(DownloadRecord.state(for: running) == .paused)
        }
        #expect(DownloadRecord.state(for: .completed) == .completed)
        #expect(DownloadRecord.state(for: .failed("x")) == .failed("x"))
        let record = fileRecord(headers: ["Cookie": "SID=1", "Authorization": "Bearer t", "Referer": "https://a.example/"])
        #expect(record.headers == ["Referer": "https://a.example/"])
        #expect(record.isUnfinished)
        #expect(!fileRecord(state: .completed).isUnfinished)
    }
}

@Suite struct DownloadRecordQueueTests {
    @Test func aRecordSavedBeforeQueuesLoadsIntoMainAndNotWaiting() throws {
        let record = fileRecord()
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object["queueID"] == nil)                       // Main is saved as no queue
        object.removeValue(forKey: "waitingInQueue")
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.queueID == nil && !decoded.waitingInQueue)
        #expect(decoded == record)
    }

    @Test func theQueueAndWaitingRoundTrip() throws {
        var record = fileRecord()
        record.queueID = Queue.laterID
        record.waitingInQueue = true
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test func aRestoredDownloadGoesToItsQueueOrMain() {
        var waiting = fileRecord()
        waiting.queueID = Queue.laterID
        waiting.waitingInQueue = true
        let placed = RestorePlanner.queuePlacement(for: waiting, existing: [Queue.mainID, Queue.laterID])
        #expect(placed.queueID == Queue.laterID && placed.waiting)
        // Its queue was deleted: Main, not waiting.
        let orphan = RestorePlanner.queuePlacement(for: waiting, existing: [Queue.mainID])
        #expect(orphan.queueID == Queue.mainID && !orphan.waiting)
        // Paused by the user, or finished: it stays where it is and doesn't wait.
        var paused = waiting
        paused.waitingInQueue = false
        #expect(!RestorePlanner.queuePlacement(for: paused, existing: [Queue.laterID]).waiting)
        var done = waiting
        done.state = .completed
        #expect(!RestorePlanner.queuePlacement(for: done, existing: [Queue.laterID]).waiting)
        // No queue at all is Main.
        #expect(RestorePlanner.queuePlacement(for: fileRecord(), existing: [Queue.laterID]).queueID == Queue.mainID)
    }
}
