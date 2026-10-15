import Foundation
import Testing
@testable import OspreyEngine

@Suite struct StorageTests {
    func tempFolder() throws -> URL {
        let url = TestTemp.root.appending(path: "storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func partFilePreallocatesAndWritesAtOffsets() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "x.bin.slpart")
        let file = try PartFile(url: url, size: 10)
        try await file.write(Data("abc".utf8), at: 5)
        try await file.write(Data("Z".utf8), at: 0)
        try await file.close()
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 10)
        #expect(bytes == Data([0x5A, 0, 0, 0, 0, 0x61, 0x62, 0x63, 0, 0]))
    }

    @Test func reopeningKeepsExistingBytes() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "y.bin.slpart")
        let first = try PartFile(url: url, size: 4)
        try await first.write(Data("ab".utf8), at: 0)
        try await first.close()
        let second = try PartFile(url: url, size: 4)
        try await second.write(Data("cd".utf8), at: 2)
        try await second.close()
        #expect(try Data(contentsOf: url) == Data("abcd".utf8))
    }

    @Test func resumeStateRoundTrips() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var map = SegmentMap(totalSize: 500)
        _ = map.nextAssignment(owned: [0], minPiece: 10)
        map.record(42, for: 0)
        let state = ResumeState(url: URL(string: "https://example.com/f.zip")!,
                                destination: folder.appending(path: "f.zip"),
                                headers: ["Referer": "https://example.com/"],
                                totalSize: 500, etag: "\"v1\"", lastModified: nil,
                                acceptsRanges: true, map: map)
        #expect(state.partURL.lastPathComponent == "f.zip.slpart")
        #expect(state.stateURL.lastPathComponent == "f.zip.slpart.json")
        try ResumeStore.save(state)
        #expect(try ResumeStore.load(from: state.stateURL) == state)
    }

    @Test func oldSidecarsWithoutOriginalURLStillLoad() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = ResumeState(url: URL(string: "https://cdn.example.com/f.zip?sig=1")!,
                                destination: folder.appending(path: "f.zip"), headers: [:],
                                totalSize: 500, etag: nil, lastModified: nil, acceptsRanges: true,
                                map: SegmentMap(totalSize: 500))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "originalURL")
        try JSONSerialization.data(withJSONObject: json).write(to: state.stateURL)
        let loaded = try ResumeStore.load(from: state.stateURL)
        #expect(loaded.url == state.url)
        #expect(loaded.originalURL == state.url)
    }

    @Test func originalURLRoundTrips() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = ResumeState(url: URL(string: "https://cdn.example.com/f.zip?sig=1")!,
                                destination: folder.appending(path: "f.zip"), headers: [:],
                                totalSize: 500, etag: nil, lastModified: nil, acceptsRanges: true,
                                map: SegmentMap(totalSize: 500),
                                originalURL: URL(string: "https://example.com/download/f.zip")!)
        try ResumeStore.save(state)
        #expect(try ResumeStore.load(from: state.stateURL).originalURL == URL(string: "https://example.com/download/f.zip")!)
    }
}
