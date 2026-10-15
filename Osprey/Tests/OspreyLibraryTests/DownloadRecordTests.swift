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
