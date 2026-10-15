import Foundation
import Testing
@testable import OspreyEngine

@Suite(.serialized) struct NetworkingTests {
    @Test func probeReadsSizeRangesAndValidators() async throws {
        let server = try TestHTTPServer(payload: testPayload(50_000))
        let url = try await server.start()
        defer { server.stop() }
        let result = try await Prober.probe(URLRequest(url: url), session: URLSession(configuration: .ephemeral))
        #expect(result.totalSize == 50_000)
        #expect(result.acceptsRanges)
        #expect(result.etag == "\"v1\"")
        #expect(result.suggestedFilename == "file.bin")
    }

    @Test func probeDetectsMissingRangeSupport() async throws {
        var config = TestHTTPServer.Config()
        config.supportsRanges = false
        let server = try TestHTTPServer(payload: testPayload(50_000), config: config)
        let url = try await server.start()
        defer { server.stop() }
        let result = try await Prober.probe(URLRequest(url: url), session: URLSession(configuration: .ephemeral))
        #expect(result.totalSize == 50_000)
        #expect(!result.acceptsRanges)
    }

    @Test func transferStreamDeliversResponseThenBytes() async throws {
        let payload = testPayload(100_000)
        let server = try TestHTTPServer(payload: payload)
        let url = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: url)
        request.setValue("bytes=10-19999", forHTTPHeaderField: "Range")
        var status = 0
        var body = Data()
        for try await event in TransferStream.events(for: request, session: URLSession(configuration: .ephemeral)) {
            switch event {
            case .response(let response): status = response.statusCode
            case .data(let data): body.append(data)
            }
        }
        #expect(status == 206)
        #expect(body == payload.subdata(in: 10..<20_000))
    }

    @Test func fatalErrors() {
        #expect(EngineError.httpStatus(404, retryAfter: nil).isFatal)
        #expect(!EngineError.httpStatus(503, retryAfter: 5).isFatal)
        #expect(!EngineError.timedOut.isFatal)
        #expect(EngineError.remoteFileChanged.isFatal)
    }
}
