import Foundation
import Testing
import OspreyEngine
@testable import OspreyMedia

private func codableFormat(_ json: String) -> MediaFormat {
    try! JSONDecoder().decode(MediaFormat.self, from: Data(json.utf8))
}

@Suite struct MediaRecordTests {
    @Test func aPlanRoundTripsThroughJSON() throws {
        let video = codableFormat(#"{"format_id":"299","ext":"mp4","protocol":"https","url":"https://media.example/299","vcodec":"avc1.64002a","acodec":"none","height":1080,"width":1920,"fps":60,"tbr":4500,"filesize":330000000,"has_drm":"maybe","language":"en","language_preference":10,"format_note":"1080p60","http_headers":{"User-Agent":"UA"}}"#)
        let audio = codableFormat(#"{"format_id":"hls-a","ext":"m4a","protocol":"m3u8_native","vcodec":"none","acodec":"mp4a.40.2","abr":129,"filesize_approx":9700000}"#)
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: Data(#"{"ext":"vtt","url":"https://subs.example/en.m3u8","name":"English","protocol":"m3u8_native"}"#.utf8))
        let plan = MediaPlan(parts: [MediaPart(format: video, role: .video), MediaPart(format: audio, role: .audio)],
                             container: .mkv, convertToMP3: false, subtitle: track, subtitleLanguage: "en",
                             subtitleAlternates: [track])
        let decoded = try JSONDecoder().decode(MediaPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        #expect(decoded.parts[0].format.possiblyProtected && !decoded.parts[0].format.hasDRM)
        #expect(decoded.parts[1].format.url == nil && decoded.parts[1].format.isFragmented)
        #expect(decoded.subtitle?.isHLS == true)
    }

    @Test func aRecordKeepsNoCredentialsAndRoundTrips() throws {
        let format = codableFormat(#"{"format_id":"18","ext":"mp4","protocol":"https","url":"https://media.example/18","http_headers":{"User-Agent":"UA","Cookie":"SID=secret","Authorization":"Bearer secret"}}"#)
        let plan = MediaPlan(parts: [MediaPart(format: format, role: .combined)], container: .mp4, convertToMP3: false,
                             subtitle: nil, subtitleLanguage: nil)
        let record = MediaRecord(video: MediaRecord.Video(id: "abc", title: "Clip"), plan: plan,
                                 folder: URL(fileURLWithPath: "/tmp/osprey-tests/Video"), hiddenFolderID: UUID(),
                                 phase: .readyToMerge, warning: .subtitlesSkipped(.refused(site: "YouTube", status: 429)))
        #expect(record.plan.parts[0].format.httpHeaders == ["User-Agent": "UA"])
        let data = try JSONEncoder().encode(record)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(try JSONDecoder().decode(MediaRecord.self, from: data) == record)
    }

    @Test func thePhaseIsReadyToMergeOnceEveryPartIsDone() {
        func part(_ state: DownloadState) -> MediaPartStatus {
            MediaPartStatus(role: .video, state: state, downloaded: 0, total: nil)
        }
        #expect(MediaRecord.Phase(MediaSnapshot(phase: .downloading, parts: [part(.completed), part(.downloading)], finalFile: nil)) == .downloading)
        #expect(MediaRecord.Phase(MediaSnapshot(phase: .merging, parts: [part(.completed), part(.completed)], finalFile: nil)) == .readyToMerge)
        #expect(MediaRecord.Phase(MediaSnapshot(phase: .paused, parts: [part(.completed), part(.completed)], finalFile: nil)) == .readyToMerge)
        #expect(MediaRecord.Phase(MediaSnapshot(phase: .paused, parts: [], finalFile: nil)) == .downloading)
    }

    @Test func theVideoKeepsWhatTheDownloadNeeds() throws {
        let json = #"{"id":"abc123","title":"Demo Talk","uploader":"Demo Channel","duration":600,"thumbnail":"https://i.example/abc.jpg","webpage_url":"https://www.youtube.com/watch?v=abc123","formats":[{"format_id":"18","ext":"mp4","protocol":"https","url":"https://media.example/18"}]}"#
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        let rebuilt = MediaRecord.Video(info).mediaInfo
        #expect(rebuilt.id == "abc123" && rebuilt.title == "Demo Talk" && rebuilt.uploader == "Demo Channel")
        #expect(rebuilt.duration == 600 && rebuilt.thumbnail == info.thumbnail && rebuilt.webpageURL == info.webpageURL)
        #expect(rebuilt.formats.isEmpty)
    }
}
