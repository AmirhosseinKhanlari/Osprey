import Foundation

public enum MediaTool: Sendable { case ytdlp, ffmpeg

    var fileName: String { self == .ytdlp ? "yt-dlp" : "ffmpeg" }

    /// Prints the version. yt-dlp skips the user's config files, which can make even `--version` fail.
    var versionArguments: [String] { self == .ytdlp ? ["--ignore-config", "--version"] : ["-version"] }
}

public struct ToolLocation: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case managed, homebrew }
    public var url: URL
    public var source: Source
}

public struct MediaTools: Sendable {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Osprey/Tools", directoryHint: .isDirectory)
    }
    public static let defaultHomebrewFolders = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]

    public let managedFolder: URL
    public let homebrewFolders: [URL]

    public init(managedFolder: URL = MediaTools.defaultFolder, homebrewFolders: [URL] = MediaTools.defaultHomebrewFolders) {
        self.managedFolder = managedFolder
        self.homebrewFolders = homebrewFolders
    }

    /// yt-dlp: managed, then Homebrew. ffmpeg: Homebrew, then managed.
    public func locate(_ tool: MediaTool) -> ToolLocation? {
        let managed = ToolLocation(url: managedFolder.appending(path: tool.fileName), source: .managed)
        let brew = homebrewFolders.map { ToolLocation(url: $0.appending(path: tool.fileName), source: .homebrew) }
        let ordered = tool == .ytdlp ? [managed] + brew : brew + [managed]
        return ordered.first { FileManager.default.isExecutableFile(atPath: $0.url.path(percentEncoded: false)) }
    }

    public func version(_ tool: MediaTool) async -> String? {
        guard let location = locate(tool) else { return nil }
        let args = tool.versionArguments
        guard let result = try? await ProcessRunner.run(location.url, args, timeout: 10), result.status == 0 else { return nil }
        let first = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first
        return first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
