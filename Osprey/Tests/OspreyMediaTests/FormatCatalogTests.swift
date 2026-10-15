import Foundation
import Testing
@testable import OspreyMedia

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func info(_ name: String) throws -> MediaInfo {
    guard case .single(let info) = try MediaProbeResult.decode(fixture(name)) else { throw CocoaError(.coderReadCorrupt) }
    return info
}

@Suite struct FormatCatalogTests {
    @Test func decodesFormatsAndKeepsStoryboardsOutOfOptions() throws {
        let i = try info("youtube_like")
        #expect(i.title == "Demo Talk" && i.formats.count == 10)
        #expect(i.formats.first { $0.formatID == "sb0" }?.isStoryboard == true)
        #expect(i.formats.first { $0.formatID == "136" }?.hasAudio == false)
        #expect(i.formats.first { $0.formatID == "136" }?.httpHeaders["User-Agent"] == "UA")
        let ids = [true, false].flatMap { FormatCatalog.videoOptions(for: i, compatible: $0) + FormatCatalog.audioOptions(for: i) }
            .flatMap { $0.plan.parts.map(\.format.formatID) }
        #expect(!ids.contains("sb0"))
    }

    @Test func compatibleOptionsPreferH264AndM4A() throws {
        let options = FormatCatalog.videoOptions(for: try info("youtube_like"), compatible: true)
        #expect(options.map(\.title) == ["2160p60", "1080p60", "720p", "360p"])
        let p1080 = try #require(options.first { $0.title == "1080p60" })
        #expect(p1080.plan.parts.map(\.format.formatID) == ["299", "140"])
        #expect(p1080.plan.container == .mp4)
        #expect(p1080.estimatedBytes == 339_700_000 && !p1080.estimateIsApproximate)
        let p2160 = try #require(options.first { $0.title == "2160p60" })
        #expect(p2160.plan.parts.map(\.format.formatID) == ["315", "251"])   // no H.264 at 2160p: VP9 + Opus
        #expect(p2160.plan.container == .mkv)
        #expect(p2160.detail.contains("VP9"))
        let p360 = try #require(options.first { $0.title == "360p" })
        #expect(p360.plan.parts.map(\.role) == [.combined] && !p360.plan.needsFFmpeg)
    }

    @Test func bestQualityModePrefersHigherBitrate() throws {
        let p720 = try #require(FormatCatalog.videoOptions(for: try info("youtube_like"), compatible: false).first { $0.title == "720p" })
        #expect(p720.plan.parts.map(\.format.formatID) == ["136", "251"])   // 136 has the higher tbr
        #expect(p720.plan.container == .mkv)                                // H.264 + Opus → mkv
    }

    @Test func approximateSizesAreFlagged() throws {
        let p720 = try #require(FormatCatalog.videoOptions(for: try info("youtube_like"), compatible: false).first { $0.title == "720p" })
        // `#expect` decomposes a literal-sum right-hand side (`a + b`) and fails to type-check it against Int64?,
        // so the sum is wrapped in an explicit Int64(...) conversion.
        #expect(p720.estimatedBytes == Int64(110_000_000 + 10_200_000))
        #expect(!p720.estimateIsApproximate)
        let vp9Only = try info("youtube_like")
        let opts = FormatCatalog.videoOptions(for: MediaInfo(copying: vp9Only, keeping: ["247", "251"]), compatible: false)
        #expect(opts.first?.estimateIsApproximate == true)
    }

    @Test func audioOptions() throws {
        let audio = FormatCatalog.audioOptions(for: try info("youtube_like"))
        #expect(audio.map(\.title) == ["Audio · M4A", "Audio · MP3"])
        #expect(audio[0].plan.parts.map(\.format.formatID) == ["140"] && audio[0].plan.container == .m4a && !audio[0].plan.convertToMP3)
        #expect(audio[1].plan.parts.map(\.format.formatID) == ["251"] && audio[1].plan.convertToMP3 && audio[1].plan.container == .mp3)
    }

    @Test func hlsFormatsAreFragmentedAndCombined() throws {
        let opts = FormatCatalog.videoOptions(for: try info("hls_only"), compatible: true)
        #expect(opts.map(\.title) == ["1080p", "480p"])
        #expect(opts[0].plan.parts.count == 1 && opts[0].plan.parts[0].format.isFragmented)
        #expect(opts[0].estimatedBytes == 75_000_000 && opts[0].estimateIsApproximate)   // tbr 5000 kbit/s × 120 s
    }

    @Test func drmOnlyIsProtected() throws {
        let i = try info("drm_only")
        #expect(FormatCatalog.isFullyProtected(i))
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).isEmpty)
    }

    @Test func capsPickTheRightPlan() throws {
        let i = try info("youtube_like")
        #expect(FormatCatalog.plan(for: i, cap: .maxHeight(1080), compatible: true)?.parts.first?.format.formatID == "299")
        #expect(FormatCatalog.plan(for: i, cap: .maxHeight(480), compatible: true)?.parts.first?.format.formatID == "18")
        #expect(FormatCatalog.plan(for: i, cap: .best, compatible: false)?.parts.first?.format.formatID == "315")
        #expect(FormatCatalog.plan(for: i, cap: .audioMP3, compatible: true)?.convertToMP3 == true)
        #expect(FormatCatalog.plan(for: i, cap: .maxHeight(144), compatible: true)?.parts.first?.format.formatID == "18")  // nothing ≤144: smallest
    }

    @Test func decodesPlaylists() throws {
        guard case .playlist(let p) = try MediaProbeResult.decode(fixture("playlist")) else { Issue.record("not a playlist"); return }
        #expect(p.title == "Course" && p.entries.count == 3 && p.entries[2].title == nil)
    }
}

// MARK: - Fix round 1

func infoJSON(_ formats: [String], duration: Int? = 100, extra: String = "") throws -> MediaInfo {
    let d = duration.map { "\"duration\":\($0)," } ?? ""
    let json = "{\"id\":\"t\",\"title\":\"T\",\(d)\"formats\":[\(formats.joined(separator: ","))]\(extra)}"
    guard case .single(let info) = try MediaProbeResult.decode(Data(json.utf8)) else { throw CocoaError(.coderReadCorrupt) }
    return info
}

func fmt(_ id: String, ext: String = "mp4", proto: String = "https", url: Bool = true, _ extra: String = "") -> String {
    "{\"format_id\":\"\(id)\",\"ext\":\"\(ext)\",\"protocol\":\"\(proto)\"\(url ? ",\"url\":\"https://m.example/\(id)\"" : "")\(extra.isEmpty ? "" : "," + extra)}"
}

@Suite struct FormatCatalogFixRound1Tests {
    // 1. classification
    @Test func formatWithNoCodecsOrHeightIsOneCombinedOption() throws {
        let i = try infoJSON([#"{"format_id":"0","ext":"mp4","protocol":"https","url":"https://m.example/0"}"#])
        let opts = FormatCatalog.videoOptions(for: i, compatible: true)
        #expect(opts.count == 1 && opts[0].title == "Original")
        #expect(opts[0].plan.parts.map(\.role) == [.combined] && opts[0].plan.container == .mp4)
        #expect(FormatCatalog.plan(for: i, cap: .best, compatible: true)?.parts.first?.role == .combined)
    }

    @Test func progressiveWithHeightButNoAcodecIsNeverPairedWithAudio() throws {
        let i = try infoJSON([fmt("p", #""vcodec":"avc1.4d401f","height":720"#),
                              fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)])
        let o = try #require(FormatCatalog.videoOptions(for: i, compatible: true).first)
        #expect(o.plan.parts.map(\.format.formatID) == ["p"] && o.plan.parts.map(\.role) == [.combined])
    }

    @Test func vcodecOnlyFormatWithoutHeightIsOffered() throws {
        let i = try infoJSON([fmt("v", #""vcodec":"avc1.4d401f""#)])
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).count == 1)
    }

    @Test func audioEvidenceStillMakesAudioOnly() throws {
        let i = try infoJSON([fmt("a", ext: "m4a", #""abr":128"#), fmt("b", ext: "opus", "")])
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).isEmpty)
        #expect(i.formats.allSatisfy { !$0.hasVideo && $0.hasAudio })
    }

    @Test func heightlessGroupSortsLastWithUniqueIDAndNoteTitle() throws {
        let i = try infoJSON([fmt("n1", #""format_note":"Source","vcodec":"avc1","acodec":"mp4a.40.2""#),
                              fmt("n2", #""vcodec":"avc1","acodec":"mp4a.40.2""#),
                              fmt("h", #""vcodec":"avc1","acodec":"mp4a.40.2","height":480"#)])
        let opts = FormatCatalog.videoOptions(for: i, compatible: true)
        #expect(opts.count == 2 && opts[0].title == "480p")
        #expect(opts[1].title == "Source")
        #expect(Set(opts.map(\.id)).count == 2)
        #expect(FormatCatalog.plan(for: i, cap: .best, compatible: true)?.parts.first?.format.formatID == "h")
    }

    @Test func bestNeverFallsBackToAudioWhenVideoExists() throws {
        let i = try infoJSON([fmt("v", #""vcodec":"avc1""#), fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)])
        #expect(FormatCatalog.plan(for: i, cap: .best, compatible: true)?.parts.first?.role != .audio)
    }

    // 2. partial DRM / decode drops
    @Test func partialDRMOffersOnlyClearFormats() throws {
        let i = try infoJSON([fmt("d", #""vcodec":"avc1","acodec":"none","height":1080,"has_drm":true"#),
                              fmt("v", #""vcodec":"avc1","acodec":"none","height":480"#),
                              fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)])
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).map(\.title) == ["480p"])
        #expect(i.protectedFormatCount == 1 && FormatCatalog.hasProtectedFormats(i) && !FormatCatalog.isFullyProtected(i))
    }

    @Test func drmOnlyWithoutURLsIsFullyProtected() throws {
        let i = try info("drm_nourl")
        #expect(FormatCatalog.isFullyProtected(i))
        #expect(i.protectedFormatCount == 3 && i.droppedFormatCount == 1)   // third format lacks format_id; has_drm still read
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).isEmpty)
    }

    @Test func directFormatsNeedURLButFragmentedDoNot() throws {
        let direct = try infoJSON([fmt("x", url: false, #""vcodec":"avc1","acodec":"mp4a.40.2","height":720"#)])
        #expect(FormatCatalog.videoOptions(for: direct, compatible: true).isEmpty)
        let frag = try infoJSON([fmt("y", proto: "m3u8_native", url: false, #""vcodec":"avc1","acodec":"mp4a.40.2","height":720"#)])
        #expect(FormatCatalog.videoOptions(for: frag, compatible: true).count == 1)
    }

    @Test func malformedFormatsAreCounted() throws {
        let i = try infoJSON([fmt("ok", #""vcodec":"avc1","height":360"#), #"{"ext":"mp4"}"#, "5"])
        #expect(i.formats.count == 1 && i.droppedFormatCount == 2 && i.protectedFormatCount == 0)
    }

    // 3. lenient numbers
    @Test func lenientNumbers() throws {
        let i = try infoJSON([fmt("f", #""vcodec":"avc1","acodec":"mp4a.40.2","height":"720","width":1280.0,"filesize":1234.6,"filesize_approx":"5000","tbr":"850.5","abr":[1],"fps":"29.97""#)])
        let f = try #require(i.formats.first)
        #expect(f.height == 720 && f.width == 1280 && f.filesize == 1235 && f.filesizeApprox == 5000)
        #expect(f.tbr == 850.5 && f.abr == nil && f.fps == 29.97)
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).first?.title == "720p")
    }

    @Test func maybeDRMIsUsableButRankedLower() throws {
        let i = try infoJSON([fmt("m", #""vcodec":"avc1","acodec":"mp4a.40.2","height":720,"tbr":1000,"has_drm":"maybe""#),
                              fmt("c", #""vcodec":"avc1","acodec":"mp4a.40.2","height":720,"tbr":1000"#)])
        let m = try #require(i.formats.first { $0.formatID == "m" })
        #expect(m.possiblyProtected && !m.hasDRM)
        #expect(FormatCatalog.videoOptions(for: i, compatible: true).first?.plan.parts.first?.format.formatID == "c")
        let only = try infoJSON([fmt("m", #""vcodec":"avc1","acodec":"mp4a.40.2","height":720,"has_drm":"maybe""#)])
        #expect(FormatCatalog.videoOptions(for: only, compatible: true).count == 1)
    }

    @Test func subtitleTrackWithoutURLIsSkipped() throws {
        let i = try infoJSON([fmt("v", #""vcodec":"avc1","height":360"#)],
                             extra: #","subtitles":{"en":[{"ext":"vtt"},{"ext":"srt","url":"https://s.example/en.srt"}]},"automatic_captions":{"fr":[{"ext":"vtt"}]}"#)
        #expect(i.subtitles["en"]?.map(\.ext) == ["srt"])
        #expect(i.automaticCaptions["fr"]?.isEmpty ?? true)
    }

    // 4. tie-breaks
    @Test func directBeatsFragmentedBeforeBitrate() throws {
        let i = try infoJSON([fmt("frag", proto: "http_dash_segments", #""vcodec":"avc1","acodec":"none","height":720,"fps":30,"tbr":3000"#),
                              fmt("direct", #""vcodec":"avc1","acodec":"none","height":720,"fps":30,"tbr":1000"#)])
        #expect(FormatCatalog.videoOptions(for: i, compatible: false).first?.plan.parts.first?.format.formatID == "direct")
    }

    @Test func nilFpsCountsAsThirty() throws {
        let i = try infoJSON([fmt("fps30", #""vcodec":"avc1","acodec":"none","height":720,"fps":30,"tbr":1000"#),
                              fmt("nofps", #""vcodec":"avc1","acodec":"none","height":720,"tbr":2000"#)])
        #expect(FormatCatalog.videoOptions(for: i, compatible: false).first?.plan.parts.first?.format.formatID == "nofps")
    }

    @Test func audioWithoutAbrRanksByTbrThenFilesize() throws {
        let byTbr = try infoJSON([fmt("a1", ext: "m4a", #""vcodec":"none","acodec":"opus","tbr":100"#),
                                  fmt("a2", ext: "m4a", #""vcodec":"none","acodec":"opus","tbr":200"#)])
        #expect(FormatCatalog.plan(for: byTbr, cap: .audioMP3, compatible: true)?.parts.first?.format.formatID == "a2")
        let bySize = try infoJSON([fmt("s1", ext: "m4a", #""vcodec":"none","acodec":"opus","filesize":1000"#),
                                   fmt("s2", ext: "m4a", #""vcodec":"none","acodec":"opus","filesize":2000"#)])
        #expect(FormatCatalog.plan(for: bySize, cap: .audioMP3, compatible: true)?.parts.first?.format.formatID == "s2")
    }

    // 5. audio options
    @Test func m4aIsNilWithoutAAC() throws {
        let i = try infoJSON([fmt("o", ext: "webm", #""vcodec":"none","acodec":"opus","abr":140"#)])
        #expect(FormatCatalog.plan(for: i, cap: .audioM4A, compatible: true) == nil)
        #expect(!FormatCatalog.audioOptions(for: i).contains { $0.id == "a-m4a" })
        #expect(FormatCatalog.plan(for: i, cap: .audioMP3, compatible: true)?.convertToMP3 == true)
    }

    @Test func mp3EstimateIs192kbpsTimesDuration() throws {
        let audio = fmt("o", ext: "webm", #""vcodec":"none","acodec":"opus","abr":140,"filesize":999"#)
        let known = try #require(FormatCatalog.audioOptions(for: try infoJSON([audio], duration: 100)).first { $0.id == "a-mp3" })
        #expect(known.estimatedBytes == 2_400_000 && known.estimateIsApproximate)
        let unknown = try #require(FormatCatalog.audioOptions(for: try infoJSON([audio], duration: nil)).first { $0.id == "a-mp3" })
        #expect(unknown.estimatedBytes == nil)
    }

    // 6. containers
    @Test func singleFormatContainers() throws {
        func container(_ ext: String) throws -> Container? {
            FormatCatalog.videoOptions(for: try infoJSON([fmt("x", ext: ext, #""vcodec":"avc1","acodec":"mp4a.40.2","height":360"#)]), compatible: true).first?.plan.container
        }
        #expect(try container("mp4") == .mp4 && container("m4v") == .mp4 && container("webm") == .webm)
        #expect(try container("flv") == .mkv && container("mov") == .mkv)
    }

    @Test func playsInQuickTime() throws {
        func qt(_ f: String, compatible: Bool = true) throws -> Bool? {
            FormatCatalog.videoOptions(for: try infoJSON([f]), compatible: compatible).first?.playsInQuickTime
        }
        #expect(try qt(fmt("a", #""vcodec":"avc1.64002a","acodec":"mp4a.40.2","height":720"#)) == true)
        #expect(try qt(fmt("b", #""vcodec":"hvc1.1.6","acodec":"none","height":720"#)) == true)
        #expect(try qt(fmt("c", ext: "webm", #""vcodec":"vp9","acodec":"opus","height":720"#)) == false)
        #expect(try qt(fmt("d", #""vcodec":"avc1","acodec":"opus","height":720"#)) == false)
        #expect(try qt(fmt("e", #""vcodec":"avc1","height":720"#)) == false)   // unknown audio: not promised
        let paired = try infoJSON([fmt("v", #""vcodec":"avc1","acodec":"none","height":720"#),
                                   fmt("o", ext: "webm", #""vcodec":"none","acodec":"opus","abr":140"#)])
        #expect(FormatCatalog.videoOptions(for: paired, compatible: false).first?.playsInQuickTime == false)
    }

    // 7. playlists
    @Test func multiVideoIsAPlaylistAndEntriesFallBackToWebpageURL() throws {
        let json = #"{"_type":"multi_video","id":"M","title":"Multi","entries":[{"id":"a","webpage_url":"https://x.example/a"},{"id":"b","url":"https://x.example/b","webpage_url":"https://x.example/other"},{"id":"c"}]}"#
        guard case .playlist(let p) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("not a playlist"); return }
        #expect(p.entries.map(\.id) == ["a", "b"])
        #expect(p.entries.map(\.url.absoluteString) == ["https://x.example/a", "https://x.example/b"])
    }
}

@Suite struct FormatCatalogTask8FixTests {
    // DRC (dynamic range compressed) audio is YouTube's quieter variant: rank it below an otherwise equal one.
    @Test func drcAudioRanksBelowItsPlainTwin() throws {
        let i = try infoJSON([fmt("140-drc", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":129.481,"tbr":129.481,"filesize":1000,"format_note":"medium, DRC""#),
                              fmt("140", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":129.481,"tbr":129.481,"filesize":1000,"format_note":"medium""#),
                              fmt("298", #""vcodec":"avc1.4D4020","acodec":"none","height":720,"tbr":2000,"filesize":5000"#)])
        #expect(FormatCatalog.audioOptions(for: i).first { $0.id == "a-m4a" }?.plan.parts.map(\.format.formatID) == ["140"])
        let p720 = try #require(FormatCatalog.videoOptions(for: i, compatible: true).first)
        #expect(p720.plan.parts.map(\.format.formatID) == ["298", "140"])
    }

    @Test func drcIsRecognisedByNoteAloneAndCaseInsensitively() throws {
        let i = try infoJSON([fmt("a1", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":130,"format_note":"medium, drc""#),
                              fmt("a2", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128,"format_note":"medium""#)])
        #expect(FormatCatalog.audioOptions(for: i).first?.plan.parts.map(\.format.formatID) == ["a2"])
    }

    static func partialVideoDRM() throws -> MediaInfo {
        try infoJSON([fmt("v", #""vcodec":"avc1","acodec":"none","height":1080,"has_drm":true"#),
                      fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)])
    }

    @Test func playlistVideoCapNeverFallsBackToAudioWhenVideoIsProtected() throws {
        let i = try Self.partialVideoDRM()
        for cap in [QualityCap.best, .maxHeight(720)] {
            #expect(FormatCatalog.playlistPlan(for: i, cap: cap, compatible: true, hasFFmpeg: true) == .failure(.protected))
        }
        // Asking for audio is fine: the audio isn't protected.
        #expect(try FormatCatalog.playlistPlan(for: i, cap: .audioM4A, compatible: true, hasFFmpeg: true).get().container == .m4a)
    }

    // An audio-only source (SoundCloud) has no video to protect: a video cap gets its audio.
    @Test func playlistVideoCapOnAudioOnlySourceUsesAudio() throws {
        let i = try infoJSON([fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)])
        for cap in [QualityCap.best, .maxHeight(1080)] {
            let plan = try FormatCatalog.playlistPlan(for: i, cap: cap, compatible: true, hasFFmpeg: true).get()
            #expect(plan.container == .m4a && plan.parts.map(\.format.formatID) == ["a"])
        }
    }

    // A malformed DRM video that was dropped while decoding still counts as protected video.
    @Test func droppedProtectedFormatStillBlocksAudioFallback() throws {
        let i = try infoJSON([#"{"format_id":"v","has_drm":true,"height":"bad","vcodec":7}"#,
                              fmt("a", ext: "m4a", #""vcodec":"none","acodec":"mp4a.40.2","abr":128"#)])
        #expect(i.protectedFormatCount == 1 && i.formats.count == 1)
        #expect(FormatCatalog.playlistPlan(for: i, cap: .best, compatible: true, hasFFmpeg: true) == .failure(.protected))
    }

    @Test func playlistFullyProtectedEntryIsProtected() throws {
        let i = try info("drm_only")
        #expect(FormatCatalog.playlistPlan(for: i, cap: .audioM4A, compatible: true, hasFFmpeg: true) == .failure(.protected))
    }

    @Test func playlistChecksFFmpegPerEntry() throws {
        let i = try info("youtube_like")
        // Original M4A needs no ffmpeg; a joined 1080p does.
        #expect((try? FormatCatalog.playlistPlan(for: i, cap: .audioM4A, compatible: true, hasFFmpeg: false).get()) != nil)
        #expect(FormatCatalog.playlistPlan(for: i, cap: .maxHeight(1080), compatible: true, hasFFmpeg: false) == .failure(.needsFFmpeg))
        // A combined 360p file needs no ffmpeg either.
        #expect((try? FormatCatalog.playlistPlan(for: i, cap: .maxHeight(360), compatible: true, hasFFmpeg: false).get())?.needsFFmpeg == false)
    }
}
