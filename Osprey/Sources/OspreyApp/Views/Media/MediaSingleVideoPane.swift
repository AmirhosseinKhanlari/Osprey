import AppKit
import OspreyMedia
import SwiftUI

/// The picker for one video. Top to bottom: the video card; a Video | Audio only switch; a row of option chips (audio
/// language, subtitles); the list of qualities (or audio formats), the only part that scrolls; then Save to and the
/// buttons, pinned at the bottom.
struct SingleVideoPane: View {
    @Environment(MediaCoordinator.self) private var media
    let info: MediaInfo
    let pageHost: String?

    @State private var mode: MediaPickerMode
    /// The chosen video quality, stable across the Compatible switch and the language menu: "h<height>".
    @State private var videoKey: String?
    /// The chosen audio-only format: the option id ("a-m4a", "a-mp3").
    @State private var audioKey: String?
    @State private var compatible: Bool
    /// The Subtitles choice; nil is Off.
    @State private var subtitle: SubtitleChoice?
    @State private var showSubtitles = false
    @State private var folderOverride: URL?
    /// The pane's content width, measured: chip labels get 40% of it, so two chips and the switch share a row.
    @State private var contentWidth: CGFloat = 0
    private var chipTextWidth: CGFloat? { contentWidth > 0 ? contentWidth * 0.4 : nil }
    @State private var didLoad = false
    /// The audio track's language code when the video has several (nil: one language, the default rules apply).
    @State private var audioLanguage: String?
    /// The user changed the language menu, so the choice is remembered.
    @State private var choseAudioLanguage = false

    private var audioLanguages: [AudioLanguage] { FormatCatalog.audioLanguages(for: info) }
    private var videoOptions: [QualityOption] {
        FormatCatalog.videoOptions(for: info, compatible: compatible, audioLanguage: audioLanguage)
    }
    private var audioOptions: [QualityOption] { FormatCatalog.audioOptions(for: info, audioLanguage: audioLanguage) }
    private var subtitleMenu: SubtitleMenu { SubtitleMenu(info: info, chosen: subtitle) }

    /// The remembered mode and Compatible choice are set here, so the first frame already shows them.
    init(info: MediaInfo, pageHost: String?, initialMode: MediaPickerMode, initialCompatible: Bool) {
        self.info = info
        self.pageHost = pageHost
        _mode = State(initialValue: initialMode)
        _compatible = State(initialValue: initialCompatible)
    }

    var body: some View {
        let videos = videoOptions
        let audios = audioOptions
        // A page with only one kind (protected video, an audio-only source) shows that kind and no switch.
        let shown: MediaPickerMode = videos.isEmpty ? .audio : (audios.isEmpty ? .video : mode)
        let options = shown == .video ? videos : audios
        let selected = options.first { Self.key($0) == (shown == .video ? videoKey : audioKey) }
        VStack(alignment: .leading, spacing: 12) {
            // "Download audio" for a page with no video at all (a SoundCloud track).
            SheetHeader(title: videos.isEmpty ? "Download audio" : "Download video", subtitle: pageHost)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
            VideoCard(info: info, isPrivate: media.request?.isPrivate ?? false)
            controls(showsSwitch: !videos.isEmpty && !audios.isEmpty, mode: shown)
            notices(videos: videos, audios: audios)
            VStack(alignment: .leading, spacing: 7) {
                if shown == .video {
                    GroupLabel(title: "Quality") {
                        CompactSwitch(title: "Compatible (MP4 / H.264)", isOn: $compatible)
                            .help("Prefer H.264 video and AAC audio in MP4, which QuickTime and every Apple device play.")
                    }
                } else {
                    GroupLabel(title: "Format")
                }
                ScrollView {
                    group(options, selected: selected, isVideo: shown == .video)
                        .padding(.bottom, 2)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Pinned at the bottom of the sheet, with the buttons (the spec's "Save to …, Cancel, and Download").
            FormGroup {
                FolderRow(folder: folder(for: selected)) { folderOverride = $0 }
            }
            Footer {
                if let selected, needsFFmpeg(selected), !media.hasFFmpeg {
                    FFmpegInstallLink(model: ffmpegModel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let error = media.ffmpegError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.error).lineLimit(2)
                }
            } buttons: {
                Button("Cancel", role: .cancel) { media.close() }
                    .buttonStyle(.capsule(.secondary, height: 36, fontSize: 13))
                    .keyboardShortcut(.cancelAction)
                Button("Download") { download(selected) }
                    .buttonStyle(.capsule(.primary, height: 36, fontSize: 13))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || (!media.hasFFmpeg && selected.map(needsFFmpeg) == true))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .onAppear(perform: loadDefaults)
        .onChange(of: compatible) { _, value in media.settings.compatible = value }
        .onChange(of: mode) { _, value in media.settings.pickerMode = value }
    }

    // MARK: Controls

    /// The Video | Audio only switch, then the option chips. The chips wrap onto a second line when they don't fit.
    @ViewBuilder
    private func controls(showsSwitch: Bool, mode shown: MediaPickerMode) -> some View {
        let audioMenu = audioLanguages.count > 1
        let showsSubtitles = shown == .video && !subtitleMenu.isEmpty
        if showsSwitch || audioMenu || showsSubtitles {
            FlowLayout(spacing: 10) {
                if showsSwitch {
                    ChipSegments(options: [(MediaPickerMode.video, "Video"), (.audio, "Audio only")], selection: $mode)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Download")
                        .accessibilityValue(mode.title)
                }
                if audioMenu { audioLanguageChip() }
                if showsSubtitles { subtitleChip() }
            }
        }
    }

    /// "Audio  English · Original ⌄" for a video with several audio tracks (dubs). Changing it rebuilds the
    /// qualities, their sizes and the audio-only formats.
    private func audioLanguageChip() -> some View {
        let languages = audioLanguages
        let current = languages.first { $0.code == audioLanguage }
        let title = current.map(Self.menuTitle) ?? ""
        return LabeledChip(label: "Audio") {
            Menu {
                ForEach(languages) { language in
                    Toggle(Self.menuTitle(language), isOn: Binding(get: { audioLanguage == language.code }, set: { _ in
                        audioLanguage = language.code
                        choseAudioLanguage = true
                    }))
                }
            } label: {
                ChipLabel(text: title, maxTextWidth: chipTextWidth)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Audio language")
            .accessibilityValue(title)
            .help("The audio track to download. English by default, else the original.")
        }
    }

    /// "Subtitles  Off ⌄": opens a popover with a search field, Off, the uploaded languages and the automatic
    /// captions. A popover, not a menu: YouTube offers ~150 auto-translated languages, too many to scroll through.
    private func subtitleChip() -> some View {
        let menu = subtitleMenu
        let current = menu.resolve(subtitle)
        let title = SubtitleMenu.title(for: current)
        return LabeledChip(label: "Subtitles") {
            Button { showSubtitles.toggle() } label: {
                ChipLabel(text: title, maxTextWidth: chipTextWidth)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $showSubtitles, arrowEdge: .bottom) {
                SubtitlePopover(menu: menu, current: current) { choice in
                    subtitle = choice
                    showSubtitles = false
                }
            }
            .accessibilityLabel("Subtitles")
            .accessibilityValue(title)
            .help("Subtitles are embedded in the video file. Auto-generated ones come from the site's speech recognition.")
        }
    }

    // MARK: Groups

    @ViewBuilder
    private func notices(videos: [QualityOption], audios: [QualityOption]) -> some View {
        if FormatCatalog.hasProtectedFormats(info) {
            if videos.isEmpty && !audios.isEmpty {
                ProtectedNotice(text: "The video is protected (DRM) and isn’t listed. Only its audio can be downloaded.")
            } else {
                ProtectedNotice(text: "Some qualities are protected (DRM) and aren’t listed.")
            }
        }
    }

    private func group(_ options: [QualityOption], selected: QualityOption?, isVideo: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                QualityRow(option: option, isSelected: selected.map(Self.key) == Self.key(option),
                           warnsQuickTime: isVideo && !option.playsInQuickTime,
                           needsFFmpeg: option.plan.needsFFmpeg && !media.hasFFmpeg,
                           ffmpegInstall: ffmpegModel,
                           showsDivider: index < options.count - 1) {
                    if isVideo { videoKey = Self.key(option) } else { audioKey = Self.key(option) }
                }
            }
        }
        .background(Theme.group, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke.opacity(0.75)))
    }

    private static func menuTitle(_ language: AudioLanguage) -> String {
        language.isOriginal ? "\(language.name) · Original" : language.name
    }

    /// The remembered language when this video has it (a chosen original means the original), else English, else the
    /// original, else the first listed.
    private static func initialAudioLanguage(_ languages: [AudioLanguage], remembered: String) -> String? {
        func base(_ code: String) -> String { String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }
        if remembered == FormatCatalog.originalAudioLanguage, let original = languages.first(where: \.isOriginal) {
            return original.code
        }
        let wanted = remembered.lowercased()
        if let exact = languages.first(where: { $0.code.lowercased() == wanted }) { return exact.code }
        if let same = languages.first(where: { base($0.code) == base(wanted) }) { return same.code }
        if let english = languages.first(where: { base($0.code) == "en" }) { return english.code }
        return (languages.first(where: \.isOriginal) ?? languages.first)?.code
    }

    // MARK: Helpers

    private var ffmpegModel: FFmpegInstallLink.Model {
        FFmpegInstallLink.Model(progress: media.ffmpegProgress) { media.installFFmpeg() }
    }

    private static func hasVideo(_ option: QualityOption) -> Bool { option.plan.parts.contains { $0.role != .audio } }

    private static func height(_ option: QualityOption) -> Int? {
        option.plan.parts.first { $0.role != .audio }?.format.height
    }

    static func key(_ option: QualityOption) -> String {
        guard hasVideo(option) else { return option.id }
        return height(option).map { "h\($0)" } ?? "h-none"
    }

    private func folder(for option: QualityOption?) -> URL {
        if let folderOverride { return folderOverride }
        let audio = option.map { !Self.hasVideo($0) } ?? false
        return audio ? media.settings.audioFolder : media.settings.videoFolder
    }

    /// Joining parts, converting to MP3 or embedding subtitles all run ffmpeg.
    private func needsFFmpeg(_ option: QualityOption) -> Bool {
        option.plan.needsFFmpeg || (Self.hasVideo(option) && subtitleMenu.resolve(subtitle) != nil)
    }

    private func loadDefaults() {
        guard !didLoad else { return }
        didLoad = true
        let settings = media.settings
        let tracks = audioLanguages
        if tracks.count > 1 { audioLanguage = Self.initialAudioLanguage(tracks, remembered: settings.audioLanguage) }
        let videos = FormatCatalog.videoOptions(for: info, compatible: compatible, audioLanguage: audioLanguage)
        // The highest height at or below the remembered one; else the lowest.
        let pick = videos.first { (Self.height($0) ?? 0) > 0 && (Self.height($0) ?? 0) <= settings.maxHeight } ?? videos.last
        videoKey = pick.map(Self.key)
        audioKey = FormatCatalog.audioOptions(for: info, audioLanguage: audioLanguage).first.map(Self.key)
        // The remembered subtitle when this video has it; otherwise Off (never another language).
        subtitle = settings.subtitleLanguage.flatMap { language in
            SubtitleMenu(info: info, chosen: nil).resolve(SubtitleChoice(language: language, isAuto: settings.subtitleIsAuto))
        }
    }

    private func download(_ option: QualityOption?) {
        guard let option else { return }
        media.download(option: option, subtitle: subtitleMenu.resolve(subtitle),
                       audioLanguage: choseAudioLanguage ? audioLanguage : nil, folder: folder(for: option))
    }
}

/// A small caption before a chip menu: "Audio  English · Original ⌄".
struct LabeledChip<Chip: View>: View {
    let label: String
    @ViewBuilder var chip: Chip

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            chip
        }
    }
}

/// The video's thumbnail (when there is one), title, and "uploader · duration".
private struct VideoCard: View {
    let info: MediaInfo
    let isPrivate: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let thumbnail = info.thumbnail {
                Thumbnail(url: thumbnail, isPrivate: isPrivate)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                let meta = [info.uploader?.nonEmpty, info.duration.flatMap { $0 > 0 ? Format.clock($0) : nil }]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.tile.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// A web thumbnail. For a private window's request it is loaded with an ephemeral session (nothing in the shared
/// disk cache); otherwise with AsyncImage. Anything but an http(s) address shows the placeholder.
private struct Thumbnail: View {
    let url: URL
    let isPrivate: Bool
    @State private var privateImage: NSImage?

    var body: some View {
        if !MediaURL.isWebURL(url) {
            Theme.tile
        } else if isPrivate {
            Group {
                if let privateImage {
                    Image(nsImage: privateImage).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.tile
                }
            }
            .task(id: url) {
                privateImage = await MediaThumbnail.load(url, isPrivate: true).flatMap(NSImage.init(data:))
            }
        } else {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.tile
                }
            }
        }
    }
}

// MARK: - Pieces only this pane uses

private struct ProtectedNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).padding(.top, 1)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A switch in the design's green.
struct CompactSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.settingsSwitch)
            .font(.system(size: 12))
    }
}

/// Save-to row: the folder as breadcrumbs; clicking opens a folder chooser.
