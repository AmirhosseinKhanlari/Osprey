import Darwin
import Foundation

/// Every temporary file and folder this test process makes lives under one root, removed when the process exits.
/// Roots left by earlier runs whose process is gone (a crash, a killed run) are removed on first use.
enum TestTemp {
    private static let prefix = "osprey-tests-engine-"

    static let root: URL = {
        let base = FileManager.default.temporaryDirectory
        removeStaleRoots(in: base)
        let url = base.appending(path: "\(prefix)\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)              // a reused pid's old folder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestTemp.root) }
        return url
    }()

    /// `root/<name>-<uuid>`; not created.
    static func unique(_ name: String) -> URL { root.appending(path: "\(name)-\(UUID().uuidString)") }

    private static func removeStaleRoots(in base: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: base.path(percentEncoded: false))) ?? [] where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? fm.removeItem(at: base.appending(path: name)) }
        }
    }
}
