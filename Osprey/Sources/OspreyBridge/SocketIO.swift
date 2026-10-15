import Darwin
import Foundation

public struct SocketError: Error, Equatable {
    public let code: Int32
    public let operation: String
}

enum SocketIO {
    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError(code: ENAMETOOLONG, operation: "address")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Reads `count` bytes, or fewer only if the peer closed the connection.
    static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + received, count - received) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError(code: errno, operation: "read")
            }
            received += n
        }
        return Data(buffer[0..<received])
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError(code: errno, operation: "write")
                }
                sent += n
            }
        }
    }

    /// Read/write timeouts and no SIGPIPE on a connected socket. The setsockopt results are deliberately
    /// best-effort: failure only means a missing timeout or a possible SIGPIPE, never a wrong answer.
    static func configure(_ fd: Int32, timeout seconds: TimeInterval) {
        let whole = max(0, seconds.rounded(.down))
        var timeout = timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}
