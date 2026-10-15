import Foundation
import Testing
@testable import OspreyBridge

/// Hands out bytes from a buffer; returns fewer than asked only at the end (the `Frame.read(using:)` contract).
final class DataReader {
    private var data: Data
    init(_ data: Data) { self.data = data }
    func read(_ count: Int) -> Data {
        let chunk = Data(data.prefix(count))
        data.removeFirst(chunk.count)
        return chunk
    }
}

@Suite struct FrameTests {
    @Test func encodesLittleEndianLengthPrefix() throws {
        let frame = try Frame.encode(Data("hello".utf8))
        #expect(Array(frame.prefix(4)) == [5, 0, 0, 0])
        #expect(frame.dropFirst(4) == Data("hello".utf8))
    }

    @Test func roundTripsSeveralFrames() throws {
        let stream = try Frame.encode(Data("a".utf8)) + Frame.encode(Data("bcd".utf8))
        let reader = DataReader(stream)
        #expect(try Frame.read(using: reader.read) == Data("a".utf8))
        #expect(try Frame.read(using: reader.read) == Data("bcd".utf8))
        #expect(try Frame.read(using: reader.read) == nil)          // clean EOF
    }

    @Test func rejectsOversizedPayloads() {
        #expect(throws: Frame.Error.tooLarge(BridgeProtocol.maxMessageBytes + 1)) {
            try Frame.encode(Data(count: BridgeProtocol.maxMessageBytes + 1))
        }
        var header = Data()
        withUnsafeBytes(of: UInt32(BridgeProtocol.maxMessageBytes + 1).littleEndian) { header.append(contentsOf: $0) }
        #expect(throws: Frame.Error.tooLarge(BridgeProtocol.maxMessageBytes + 1)) {
            try Frame.read(using: DataReader(header).read)
        }
    }

    @Test func truncatedHeaderOrBodyThrows() throws {
        #expect(throws: Frame.Error.truncated) { try Frame.read(using: DataReader(Data([1, 0])).read) }
        let cut = try Frame.encode(Data("hello".utf8)).prefix(6)
        #expect(throws: Frame.Error.truncated) { try Frame.read(using: DataReader(Data(cut)).read) }
    }

    @Test func readsFramesSplitAcrossPipeWrites() throws {
        let pipe = Pipe()
        let frame = try Frame.encode(Data("split".utf8))
        pipe.fileHandleForWriting.write(frame.prefix(2))
        pipe.fileHandleForWriting.write(frame.dropFirst(2).prefix(4))
        pipe.fileHandleForWriting.write(frame.dropFirst(6))
        try pipe.fileHandleForWriting.close()
        #expect(try Frame.read(from: pipe.fileHandleForReading) == Data("split".utf8))
        #expect(try Frame.read(from: pipe.fileHandleForReading) == nil)
    }
}

@Suite struct MessageTests {
    @Test func decodesAChromeCaptureMessage() throws {
        let json = #"{"v":1,"type":"capture","url":"https://x.test/a.zip","size":42,"private":true,"source":"menu"}"#
        let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        #expect(request == .capture(url: "https://x.test/a.zip", size: 42, isPrivate: true, source: .menu))
    }

    @Test func encodesPrivateUnderItsWireName() throws {
        let data = try JSONEncoder().encode(BridgeRequest.capture(url: "https://x.test/a.zip", isPrivate: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["private"] as? Bool == true)
        #expect(object["isPrivate"] == nil)
        #expect(object["referrer"] == nil)          // nil fields are omitted
    }

    @Test func mediaRoundTripsWithButtonSource() throws {
        let request = BridgeRequest.media(url: "https://x.test/watch", title: "Clip", cookies: "a=1", isPrivate: true, source: .button)
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "media" && object["source"] as? String == "button")
        #expect(object["title"] as? String == "Clip" && object["private"] as? Bool == true)
        #expect(try JSONDecoder().decode(BridgeRequest.self, from: data) == request)
        let old = try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"v":1,"type":"capture","url":"https://x.test/a","source":"auto"}"#.utf8))
        #expect(old.source == .auto)
    }

    @Test func rulesWithoutVideoButtonDecodeAsTrue() throws {
        let rules = try JSONDecoder().decode(CaptureRules.self, from: Data(#"{"enabled":true,"extensions":["zip"],"captureInPrivate":false}"#.utf8))
        #expect(rules.videoButton)
        let off = CaptureRules(enabled: true, extensions: [], captureInPrivate: false, videoButton: false)
        #expect(try JSONDecoder().decode(CaptureRules.self, from: JSONEncoder().encode(off)).videoButton == false)
    }

    @Test func unknownTypeFailsToDecode() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"v":1,"type":"bogus"}"#.utf8))
        }
    }

    @Test func responsesEncodeErrorCodesAndHelpers() throws {
        let failure = try JSONEncoder().encode(BridgeResponse.failure(.unsupportedVersion))
        #expect(String(decoding: failure, as: UTF8.self).contains(#""error":"unsupported-version""#))
        let internalError = try JSONEncoder().encode(BridgeResponse.failure(.internalError))
        #expect(String(decoding: internalError, as: UTF8.self).contains(#""error":"internal""#))
        #expect(BridgeResponse.capture(taken: true).wasTaken)
        #expect(!BridgeResponse.capture(taken: false, reason: "private").wasTaken)
        #expect(!BridgeResponse.failure(.disabled).wasTaken)
        let rules = CaptureRules(enabled: true, extensions: ["zip"], captureInPrivate: false)
        let hello = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(BridgeResponse.hello(version: "1.0", rules: rules)))
        #expect(hello.rules == rules && hello.version == "1.0" && hello.ok)
    }
}
