import Foundation

/// One preallocated (sparse on APFS) file written at arbitrary offsets.
/// No per-chunk temp files and no join step at the end.
public actor PartFile {
    private let handle: FileHandle

    public init(url: URL, size: Int64) throws {
        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
    }

    public func write(_ data: Data, at offset: Int64) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    public func synchronize() throws { try handle.synchronize() }

    public func close() throws { try handle.close() }
}
