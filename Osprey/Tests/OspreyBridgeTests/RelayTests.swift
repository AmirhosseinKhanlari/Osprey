import Foundation
import Testing
@testable import OspreyBridge

struct RelayFailure: Error {}

/// Writes request frames into a pipe, runs the relay and returns the exit code and decoded replies.
func runHost(_ messages: [String], origin: String? = BridgeLocation.chromeExtensionOrigin,
             send: (BridgeRequest) throws -> BridgeResponse) throws -> (Int32, [BridgeResponse]) {
    let input = Pipe()
    let output = Pipe()
    for message in messages { input.fileHandleForWriting.write(try Frame.encode(Data(message.utf8))) }
    try input.fileHandleForWriting.close()
    let code = HostRelay.run(input: input.fileHandleForReading, output: output.fileHandleForWriting, origin: origin, send: send)
    try output.fileHandleForWriting.close()
    var replies: [BridgeResponse] = []
    while let frame = try Frame.read(from: output.fileHandleForReading) {
        replies.append(try JSONDecoder().decode(BridgeResponse.self, from: frame))
    }
    return (code, replies)
}

@Suite struct RelayTests {
    @Test func relaysEveryFrameInOrder() throws {
        let (code, replies) = try runHost([#"{"v":1,"type":"hello"}"#, #"{"v":1,"type":"capture","url":"https://x.test/a.zip"}"#]) { request in
            request.type == .hello ? .hello(version: "1", rules: CaptureRules(enabled: true, extensions: [], captureInPrivate: false))
                                   : .capture(taken: true)
        }
        #expect(code == 0)
        #expect(replies.count == 2)
        #expect(replies[0].version == "1")
        #expect(replies[1].wasTaken)
    }

    @Test func unreachableAppRepliesUnavailable() throws {
        let (_, replies) = try runHost([#"{"v":1,"type":"hello"}"#]) { _ in throw RelayFailure() }
        #expect(replies == [.failure(.unavailable)])
    }

    @Test func notRunningMapsToNotRunningAndOtherErrorsToUnavailable() throws {
        let (_, replies) = try runHost([#"{"v":1,"type":"hello"}"#]) { _ in throw BridgeClientError.notRunning }
        #expect(replies == [.failure(.notRunning)])
        let (_, others) = try runHost([#"{"v":1,"type":"hello"}"#]) { _ in throw BridgeClientError.noReply }
        #expect(others == [.failure(.unavailable)])
    }

    @Test func garbageGetsBadRequest() throws {
        let (_, replies) = try runHost(["{nope"]) { _ in .capture(taken: true) }
        #expect(replies == [.failure(.badRequest)])
    }

    @Test func foreignOriginsAreRefused() throws {
        let (code, replies) = try runHost([#"{"v":1,"type":"hello"}"#], origin: "chrome-extension://someoneelse/") { _ in .capture(taken: true) }
        #expect(code == 1)
        #expect(replies.isEmpty)
    }

    @Test func truncatedInputExitsWithError() throws {
        let input = Pipe()
        let output = Pipe()
        input.fileHandleForWriting.write(Data([9, 0, 0, 0, 1]))     // header promises 9 bytes, only 1 follows
        try input.fileHandleForWriting.close()
        let code = HostRelay.run(input: input.fileHandleForReading, output: output.fileHandleForWriting, origin: nil) { _ in .capture(taken: true) }
        #expect(code == 1)
    }

    @Test func closedOutputPipeExitsWithErrorInsteadOfCrashing() throws {
        signal(SIGPIPE, SIG_IGN)     // process-wide; the host does the same in main.swift
        let input = Pipe()
        let output = Pipe()
        input.fileHandleForWriting.write(try Frame.encode(Data(#"{"v":1,"type":"hello"}"#.utf8)))
        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
        let code = HostRelay.run(input: input.fileHandleForReading, output: output.fileHandleForWriting, origin: nil) { _ in .capture(taken: true) }
        #expect(code == 1)
    }
}
