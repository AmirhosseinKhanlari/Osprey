import Foundation
import Testing
@testable import OspreyMedia

/// Numbers in yt-dlp's JSON come from the site. None of them may trap (overflow or a Double→Int conversion).
@Suite struct NumericSafetyTests {
    private func info(duration: String, formats: [String]) throws -> MediaInfo {
        let json = #"{"id":"x","title":"T","duration":\#(duration),"formats":[\#(formats.joined(separator: ","))]}"#
        guard case .single(let info) = try MediaProbeResult.decode(Data(json.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        return info
    }

    private let video = #"{"format_id":"v","ext":"mp4","protocol":"https","url":"https://m.example/v","vcodec":"avc1.4d401f","acodec":"none","height":720"#
    private let audio = #"{"format_id":"a","ext":"m4a","protocol":"https","url":"https://m.example/a","vcodec":"none","acodec":"mp4a.40.2""#

    @Test func hugeFileSizesDoNotOverflowTheEstimate() throws {
        let info = try info(duration: "60", formats: [video + #","filesize":9223372036854775807}"#,
                                                      audio + #","filesize":9223372036854775807}"#])
        let option = try #require(FormatCatalog.videoOptions(for: info, compatible: true).first)
        #expect(option.estimatedBytes == nil)            // unknown rather than a wrapped or trapped sum
        let (bytes, _) = FormatCatalog.estimate(info.formats, duration: info.duration)
        #expect(bytes == nil)
    }

    @Test func hugeBitrateTimesDurationGivesNoEstimate() throws {
        let info = try info(duration: "1e300", formats: [video + #","tbr":1e300}"#, audio + #","abr":1e300}"#])
        let options = FormatCatalog.videoOptions(for: info, compatible: true)
        #expect(options.first?.estimatedBytes == nil)
        let mp3 = FormatCatalog.audioOptions(for: info).first { $0.id == "a-mp3" }
        #expect(mp3 != nil && mp3?.estimatedBytes == nil)
    }

    @Test func hugeFpsDoesNotTrapTheTitle() throws {
        let info = try info(duration: "60", formats: [video + #","fps":1e300}"#, audio + "}"])
        let option = try #require(FormatCatalog.videoOptions(for: info, compatible: true).first)
        #expect(option.title.hasPrefix("720p"))
        #expect(option.title.count < 20)
    }

    @Test(arguments: [#""nan""#, #""inf""#, #""-inf""#, "-5", #""abc""#, "Infinity", "NaN", "-Infinity"])
    func oddDurationsBecomeUnknown(_ raw: String) throws {
        let info = try info(duration: raw, formats: [video + #","tbr":1000}"#])
        #expect(info.duration == nil)
        #expect(FormatCatalog.videoOptions(for: info, compatible: true).first?.estimatedBytes == nil)
    }

    @Test func nonFiniteRatesAreIgnored() throws {
        let info = try info(duration: "60", formats: [video + #","tbr":"inf","fps":"nan","filesize":"inf"}"#])
        let format = try #require(info.formats.first)
        #expect(format.tbr == nil && format.fps == nil && format.filesize == nil)
        #expect(FormatCatalog.videoOptions(for: info, compatible: true).first?.estimatedBytes == nil)
    }

    @Test func negativeSizesAreIgnored() throws {
        let info = try info(duration: "60", formats: [video + #","filesize":-5,"filesize_approx":-7,"tbr":-1}"#])
        let format = try #require(info.formats.first)
        #expect(format.filesize == nil && format.filesizeApprox == nil && format.tbr == nil)
    }

    @Test func sensibleNumbersStillEstimate() throws {
        let info = try info(duration: "10", formats: [video + #","tbr":800}"#, audio + #","filesize":1000}"#])
        let (bytes, approx) = FormatCatalog.estimate(info.formats, duration: info.duration)
        #expect(bytes == 1_001_000 && approx)
        #expect(FormatCatalog.audioOptions(for: info).first { $0.id == "a-mp3" }?.estimatedBytes == 240_000)
    }

    @Test func playlistEntryDurationsAreChecked() throws {
        let json = #"{"_type":"playlist","id":"P","title":"P","entries":[{"id":"a","url":"https://x.test/a","duration":"inf"},{"id":"b","url":"https://x.test/b","duration":1e300}]}"#
        guard case .playlist(let list) = try MediaProbeResult.decode(Data(json.utf8)) else { Issue.record("expected playlist"); return }
        #expect(list.entries.map(\.id) == ["a", "b"])
        #expect(list.entries[0].duration == nil)
        #expect(MediaText.clock(list.entries[1].duration ?? 0) == nil)
    }

    @Test func clockIsSafeForAnyDouble() {
        #expect(MediaText.clock(596) == "9:56")
        #expect(MediaText.clock(3723) == "1:02:03")
        #expect(MediaText.clock(0.4) == "0:00")
        #expect(MediaText.clock(.nan) == nil)
        #expect(MediaText.clock(.infinity) == nil)
        #expect(MediaText.clock(1e300) == nil)
        #expect(MediaText.clock(-3) == nil)
        #expect(MediaText.clock(Double(Int.max)) == nil)
    }
}
