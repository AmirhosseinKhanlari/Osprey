import Darwin
import Foundation

/// Merges separately downloaded video and audio (and an optional subtitle) with ffmpeg, or converts audio to MP3.
public struct Muxer: Sendable {
    private let tools: MediaTools

    public init(tools: MediaTools) { self.tools = tools }

    public func mux(video: URL, audio: URL, subtitle: URL?, container: Container, to output: URL) async throws {
        try await mux(video: video, audio: audio, subtitle: subtitle, subtitleLanguage: nil, container: container, to: output)
    }

    public func mux(video: URL, audio: URL, subtitle: URL?, subtitleLanguage: String?, container: Container,
                    to output: URL) async throws {
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", Self.path(video), "-i", Self.path(audio)]
        if let subtitle { args += ["-i", Self.path(subtitle)] }
        args += ["-map", "0:v:0", "-map", "1:a:0"]
        if subtitle != nil { args += ["-map", "2:s:0"] }
        args += ["-c", "copy"]
        if subtitle != nil {
            // mp4 takes mov_text and webm only WebVTT; mkv keeps SRT as is.
            if container == .mp4 { args += ["-c:s", "mov_text"] } else if container == .webm { args += ["-c:s", "webvtt"] }
            // Without a tag players list the track as "Unknown".
            if let tag = subtitleLanguage.flatMap(Self.languageTag) { args += ["-metadata:s:s:0", "language=\(tag)"] }
        }
        try await run(args, output: output, fallbackExtension: container.fileExtension)
    }

    /// The ISO 639-2 code ffmpeg writes as a stream's language: "fr" → "fra", "en-orig" → "eng", "pt-BR" → "por".
    /// Nil for anything that isn't a known language code.
    public static func languageTag(_ code: String) -> String? {
        let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard (2...3).contains(base.count), base.allSatisfy({ $0.isASCII && $0.isLetter }),
              let alpha3 = Locale.LanguageCode(base).identifier(.alpha3), alpha3.count == 3 else { return nil }
        return alpha3
    }

    public func convertToMP3(_ input: URL, to output: URL) async throws {
        try await run(["-y", "-hide_banner", "-loglevel", "error", "-i", Self.path(input),
                       "-vn", "-c:a", "libmp3lame", "-q:a", "2"], output: output, fallbackExtension: "mp3")
    }

    /// Where ffmpeg writes before the result is moved to `output`: `<name>.osprey-partial.<ext>`, a name nothing else
    /// uses (the launch sweep relies on it, together with `MediaCleanup.partialAttribute`). The extension picks the container.
    public static func partialURL(for output: URL, fallbackExtension: String) -> URL {
        let ext = output.pathExtension.isEmpty ? fallbackExtension : output.pathExtension
        return output.deletingPathExtension().appendingPathExtension("osprey-partial").appendingPathExtension(ext)
    }

    /// ffmpeg writes the partial file (overwriting an empty placeholder that reserved the name); on success it is renamed
    /// to `output`, which must not exist: a file there that this merge didn't create is never replaced.
    private func run(_ arguments: [String], output: URL, fallbackExtension: String) async throws {
        guard let ffmpeg = tools.locate(.ffmpeg) else { throw MediaError.toolMissing("ffmpeg") }
        let partial = Self.partialURL(for: output, fallbackExtension: fallbackExtension)
        let fm = FileManager.default
        do {
            // The partial file exists before ffmpeg runs (MediaDownload reserves it; otherwise it's created here) and carries
            // Osprey's mark; ffmpeg's -y truncates it in place, which keeps the mark.
            let fd = open(Self.path(partial), O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw MediaError.muxFailed("couldn't create the output file") }
            close(fd)
            try MediaCleanup.markAsPartial(partial)
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(ffmpeg.url, arguments + [Self.path(partial)], timeout: 3600)
            } catch MediaError.timedOut {
                throw MediaError.muxFailed("ffmpeg took too long")
            }
            guard result.status == 0 else {
                let last = MediaExtractor.redactURLs(result.stderr).split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "ffmpeg failed"
                throw MediaError.muxFailed(String(last.prefix(200)))
            }
            // Atomic, and fails instead of replacing when the name was taken meanwhile.
            guard renamex_np(Self.path(partial), Self.path(output), UInt32(RENAME_EXCL)) == 0 else {
                throw MediaError.muxFailed(errno == EEXIST ? "a file with that name already exists" : "couldn't save the merged file")
            }
            MediaCleanup.unmarkPartial(output)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private static func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}
