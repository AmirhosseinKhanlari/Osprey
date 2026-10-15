import Foundation
import Testing
@testable import OspreyMedia

private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
private let ffprobePath = "/opt/homebrew/bin/ffprobe"

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpegPath))) struct MuxerTests {
    private func workFolder() throws -> URL {
        let dir = TestTemp.root.appending(path: "muxer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ffmpeg(_ args: [String]) async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: ffmpegPath), ["-y", "-hide_banner", "-loglevel", "error"] + args, timeout: 60)
        #expect(r.status == 0, "\(r.stderr)")
    }

    private func probe(_ file: URL, entries: String) async throws -> [String] {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: ffprobePath),
                                            ["-v", "error", "-show_entries", entries, "-of", "csv=p=0", file.path(percentEncoded: false)], timeout: 30)
        return String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    private func media(in dir: URL) async throws -> (video: URL, audio: URL) {
        let v = dir.appending(path: "v.mp4"), a = dir.appending(path: "a.m4a")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-c:v", "libx264", "-t", "1", v.path(percentEncoded: false)])
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440", "-c:a", "aac", "-t", "1", a.path(percentEncoded: false)])
        return (v, a)
    }

    private var muxer: Muxer { Muxer(tools: MediaTools(managedFolder: URL(fileURLWithPath: "/nonexistent"))) }

    @Test func muxesVideoAndAudioIntoMP4() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let out = dir.appending(path: "out.mp4")
        try await muxer.mux(video: v, audio: a, subtitle: nil, container: .mp4, to: out)
        let types = Set(try await probe(out, entries: "stream=codec_type"))
        #expect(types == ["video", "audio"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "out.osprey-partial.mp4").path(percentEncoded: false)))
        #expect(!MediaCleanup.isMarkedPartial(out))          // the finished file doesn't keep the partial mark
    }

    /// The final name is reserved before ffmpeg runs; a file that appears there anyway (another merge, the user) is
    /// never replaced.
    @Test func neverReplacesAnExistingOutput() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let out = dir.appending(path: "out.mp4")
        try Data("old".utf8).write(to: out)
        await #expect(throws: MediaError.self) {
            try await muxer.mux(video: v, audio: a, subtitle: nil, container: .mp4, to: out)
        }
        #expect(try Data(contentsOf: out) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "out.osprey-partial.mp4").path(percentEncoded: false)))
    }

    @Test func muxesASubtitleIntoMP4() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let srt = dir.appending(path: "s.srt")
        try "1\n00:00:00,000 --> 00:00:00,800\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        let out = dir.appending(path: "out.mp4")
        try await muxer.mux(video: v, audio: a, subtitle: srt, container: .mp4, to: out)
        #expect(Set(try await probe(out, entries: "stream=codec_type")) == ["video", "audio", "subtitle"])
    }

    /// The stream is tagged with the chosen language (ISO 639-2), so players show "French", not "Unknown".
    @Test func tagsTheSubtitleWithItsLanguage() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let out = dir.appending(path: "out.mp4")
        try await muxer.mux(video: v, audio: a, subtitle: try srtFile(in: dir), subtitleLanguage: "fr", container: .mp4, to: out)
        #expect(try await probe(out, entries: "stream=codec_type:stream_tags=language").contains("subtitle,fra"))
    }

    @Test func subtitleLanguageTags() {
        #expect(Muxer.languageTag("fr") == "fra")
        #expect(Muxer.languageTag("en-orig") == "eng")
        #expect(Muxer.languageTag("pt-BR") == "por")
        #expect(Muxer.languageTag("zh-Hant") == "zho")
        #expect(Muxer.languageTag("fil") == "fil")
        #expect(Muxer.languageTag("") == nil)
        #expect(Muxer.languageTag("x;rm") == nil)
    }

    private func srtFile(in dir: URL) throws -> URL {
        let srt = dir.appending(path: "s.srt")
        try "1\n00:00:00,000 --> 00:00:00,800\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        return srt
    }

    @Test func muxesAnSRTSubtitleIntoMKV() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let out = dir.appending(path: "out.mkv")
        try await muxer.mux(video: v, audio: a, subtitle: try srtFile(in: dir), container: .mkv, to: out)
        #expect(Set(try await probe(out, entries: "stream=codec_type")) == ["video", "audio", "subtitle"])
    }

    @Test func muxesASubtitleIntoWebMAsWebVTT() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = dir.appending(path: "v.webm"), a = dir.appending(path: "a.webm")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-c:v", "libvpx-vp9", "-t", "1", v.path(percentEncoded: false)])
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440", "-c:a", "libopus", "-t", "1", a.path(percentEncoded: false)])
        let out = dir.appending(path: "out.webm")
        try await muxer.mux(video: v, audio: a, subtitle: try srtFile(in: dir), container: .webm, to: out)
        #expect(Set(try await probe(out, entries: "stream=codec_type")) == ["video", "audio", "subtitle"])
        #expect(try await probe(out, entries: "stream=codec_name").contains("webvtt"))
    }

    @Test func outputWithoutAnExtensionUsesTheContainerExtension() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let out = dir.appending(path: "movie")
        try await muxer.mux(video: v, audio: a, subtitle: nil, container: .mp4, to: out)
        #expect(Set(try await probe(out, entries: "stream=codec_type")) == ["video", "audio"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "movie.osprey-partial.mp4").path(percentEncoded: false)))
    }

    @Test func aFailedMuxKeepsTheOldOutput() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "out.mp4")
        try Data("old".utf8).write(to: out)
        await #expect(throws: (any Error).self) {
            try await muxer.mux(video: dir.appending(path: "nope.mp4"), audio: dir.appending(path: "nope.m4a"), subtitle: nil, container: .mp4, to: out)
        }
        #expect(try Data(contentsOf: out) == Data("old".utf8))
    }

    @Test func convertsToMP3() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (_, a) = try await media(in: dir)
        let out = dir.appending(path: "out.mp3")
        try await muxer.convertToMP3(a, to: out)
        #expect(try await probe(out, entries: "stream=codec_name") == ["mp3"])
    }

    /// Fix round 3 (R1): a title at the 240-byte name limit still merges and converts. The final name, its
    /// `.osprey-partial` file and the " 2" next name all fit in 255 bytes, keeping " [id]" and the extension.
    @Test func aMaximumLengthTitleMergesAndConverts() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (v, a) = try await media(in: dir)
        let title = String(repeating: "t", count: 240)
        for (ext, isMP3) in [("mp4", false), ("mp3", true), ("webm", false)] where ext != "webm" || !isMP3 {
            let name = MediaDownload.mediaFileName(title: title, id: "aqz-KE-bpKQ", ext: ext)
            #expect(name.hasSuffix(" [aqz-KE-bpKQ].\(ext)") && name.hasPrefix("ttt"))
            let first = try MediaDownload.reserveName(in: dir, name: name)
            let second = try MediaDownload.reserveName(in: dir, name: name)          // the next name, " 2"
            for output in [first, second] {
                let partial = Muxer.partialURL(for: output, fallbackExtension: ext)
                #expect(output.lastPathComponent.utf8.count <= 255 && partial.lastPathComponent.utf8.count <= 255)
                #expect(output.lastPathComponent.hasSuffix(".\(ext)") && output.lastPathComponent.contains("[aqz-KE-bpKQ]"))
            }
            #expect(second.lastPathComponent.hasSuffix(" [aqz-KE-bpKQ] 2.\(ext)"))
            if ext == "webm" { continue }
            if isMP3 {
                try await muxer.convertToMP3(a, to: first)
                #expect(try await probe(first, entries: "stream=codec_name") == ["mp3"])
            } else {
                try await muxer.mux(video: v, audio: a, subtitle: nil, container: .mp4, to: first)
                #expect(Set(try await probe(first, entries: "stream=codec_type")) == ["video", "audio"])
            }
        }
    }

    @Test func mediaFileNamesKeepTheIdAndExtensionWithinTheBudget() {
        let short = MediaDownload.mediaFileName(title: "My Clip", id: "abc", ext: "mp4")
        #expect(short == "My Clip [abc].mp4")
        // Multi-byte titles are cut on a character boundary.
        let long = MediaDownload.mediaFileName(title: String(repeating: "é", count: 200), id: "abc", ext: "mkv")
        #expect(long.hasSuffix(" [abc].mkv") && long.utf8.count + ".osprey-partial".utf8.count + 6 <= 255)
        #expect(long.hasPrefix("ééé"))
    }

    @Test func missingInputThrowsMuxFailed() async throws {
        let dir = try workFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "out.mp4")
        do {
            try await muxer.mux(video: dir.appending(path: "nope.mp4"), audio: dir.appending(path: "nope.m4a"), subtitle: nil, container: .mp4, to: out)
            Issue.record("expected muxFailed")
        } catch let error as MediaError {
            guard case .muxFailed(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!detail.isEmpty)
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(left.isEmpty)           // no partial file left behind
    }

    @Test func missingFFmpegIsToolMissing() async throws {
        let empty = MediaTools(managedFolder: TestTemp.root.appending(path: "none-\(UUID().uuidString)"), homebrewFolders: [])
        await #expect(throws: MediaError.toolMissing("ffmpeg")) {
            try await Muxer(tools: empty).convertToMP3(URL(fileURLWithPath: "/tmp/a.m4a"), to: URL(fileURLWithPath: "/tmp/a.mp3"))
        }
    }
}
