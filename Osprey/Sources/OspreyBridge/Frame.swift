import Foundation

/// Chrome native messaging and the Osprey socket share one framing:
/// a 4-byte little-endian length, then that many bytes of UTF-8 JSON.
public enum Frame {
    public enum Error: Swift.Error, Equatable {
        case tooLarge(Int)
        case truncated
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= BridgeProtocol.maxMessageBytes else { throw Error.tooLarge(payload.count) }
        var frame = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Reads one frame. `readExactly(n)` must return `n` bytes, or fewer only at end of input.
    /// Returns nil at a clean end of input before a header.
    public static func read(using readExactly: (Int) throws -> Data) throws -> Data? {
        let header = try readExactly(4)
        if header.isEmpty { return nil }
        guard header.count == 4 else { throw Error.truncated }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length <= BridgeProtocol.maxMessageBytes else { throw Error.tooLarge(length) }
        let body = try readExactly(length)
        guard body.count == length else { throw Error.truncated }
        return body
    }

    public static func read(from handle: FileHandle) throws -> Data? {
        try read { count in
            var data = Data()
            while data.count < count {
                guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return data
        }
    }
}
