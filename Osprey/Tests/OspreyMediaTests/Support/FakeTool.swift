import Foundation

struct FakeTool {
    let folder: URL
    var executable: URL { folder.appending(path: "yt-dlp") }
    var argsFile: URL { folder.appending(path: "args.txt") }

    /// - stdoutLines/lineDelay: printed one by one, `lineDelay` seconds after each.
    /// - writesDestination: writes a few bytes to the path that follows `-o`.
    /// - trapInterrupt: SIGINT makes the script exit 130 (like yt-dlp saving its state).
    /// - hang: after printing, waits (up to 30 s) so a test can pause or kill it. `hangFirstRunOnly` hangs only the first launch.
    /// - ignoreInterrupt: SIGINT is ignored, so only SIGKILL stops it.
    /// - grandchildPIDFile: spawns a background `sleep 30` (which inherits the pipes) and records its pid.
    init(stdoutFile: URL? = nil, stdoutLines: [String] = [], lineDelay: Double = 0, stderr: String = "", exitCode: Int32 = 0,
         sleepSeconds: Int = 0, writesDestination: Bool = false, trapInterrupt: Bool = false,
         hang: Bool = false, hangFirstRunOnly: Bool = false, grandchildPIDFile: URL? = nil, ignoreInterrupt: Bool = false) throws {
        folder = TestTemp.root.appending(path: "fake-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = folder.path(percentEncoded: false)
        var script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(dir)/args.txt'\n"
        // The marker proves SIGINT was delivered to the script.
        if trapInterrupt { script += "trap 'touch \"\(dir)/got-int\"; exit 130' INT\n" }
        if ignoreInterrupt { script += "trap '' INT\n" }
        // Decide up front (before any output a test may react to) whether this launch hangs, so a pause right after
        // the first progress line can't beat the marker and make the relaunch hang too.
        if hangFirstRunOnly {
            script += "hang_now=0\nif [ ! -f '\(dir)/ran' ]; then touch '\(dir)/ran'; hang_now=1; fi\n"
        }
        if let pidFile = grandchildPIDFile {
            script += "sleep 30 &\necho $! > '\(pidFile.path(percentEncoded: false))'\n"
        }
        if writesDestination {
            script += "dest=''; prev=''\nfor a in \"$@\"; do if [ \"$prev\" = '-o' ]; then dest=\"$a\"; fi; prev=\"$a\"; done\n"
            script += "[ -n \"$dest\" ] && printf 'data' > \"$dest\"\n"
        }
        if sleepSeconds > 0 { script += "sleep \(sleepSeconds)\n" }
        if let stdoutFile { script += "cat '\(stdoutFile.path(percentEncoded: false))'\n" }
        for line in stdoutLines {
            script += "printf '%s\\n' '\(line.replacingOccurrences(of: "'", with: ""))'\n"
            if lineDelay > 0 { script += "sleep \(lineDelay)\n" }
        }
        if hangFirstRunOnly {
            script += "if [ \"$hang_now\" = 1 ]; then sleep 30 & wait $!; fi\n"
        } else if hang {
            script += "sleep 30 & wait $!\n"
        }
        if !stderr.isEmpty { script += "printf '%s\\n' '\(stderr.replacingOccurrences(of: "'", with: ""))' >&2\n" }
        script += "exit \(exitCode)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    func arguments() throws -> [String] {
        try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    var sigintMarker: URL { folder.appending(path: "got-int") }

    /// Puts an executable `ffmpeg` next to the fake yt-dlp (found through the managed folder).
    func addFakeFFmpeg() throws {
        let url = folder.appending(path: "ffmpeg")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

/// Polls `condition` every 20 ms until it holds or `timeout` passes.
func waitUntil(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// True when no process with this pid exists any more.
func processIsGone(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

func readPID(_ file: URL) -> pid_t? {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}
