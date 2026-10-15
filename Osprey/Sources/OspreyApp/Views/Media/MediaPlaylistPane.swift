import AppKit
import OspreyMedia
import SwiftUI

/// The picker for a playlist: the entries to download, one quality for all of them, and the save folder.
struct PlaylistPane: View {
    @Environment(MediaCoordinator.self) private var media
    let list: PlaylistInfo
    let pageHost: String?

    @State private var selection: Set<Int> = []
    @State private var cap: QualityCap = .best
    @State private var compatible: Bool
    @State private var folderOverride: URL?
    /// The pane's content width, measured: chip labels get 40% of it.
    @State private var contentWidth: CGFloat = 0
    /// Checklist rows on screen, for the title resolver.
    @State private var visibleRows: Set<Int> = []
    private var chipTextWidth: CGFloat? { contentWidth > 0 ? contentWidth * 0.4 : nil }
    @State private var didLoad = false
    /// The user picked a quality, so a late "this playlist is music" doesn't change it.
    @State private var choseCap = false
    /// More than 50 entries: Download first asks "Add 444 tracks?".
    @State private var confirmingLarge = false

    private static let largeBatch = 50
    /// Each entry's audio language: a code, or `FormatCatalog.originalAudioLanguage`. English by default.
    @State private var audioLanguage = FormatCatalog.defaultAudioLanguage

    private static let caps: [(QualityCap, String)] = [
        (.best, "Best"), (.maxHeight(2160), "≤ 2160p"), (.maxHeight(1440), "≤ 1440p"), (.maxHeight(1080), "≤ 1080p"),
        (.maxHeight(720), "≤ 720p"), (.maxHeight(480), "≤ 480p"), (.audioM4A, "Audio · M4A"), (.audioMP3, "Audio · MP3"),
    ]

    private var isAudio: Bool { Self.isAudioCap(cap) }

    /// What the header counts: tracks for music, videos on a video site, items otherwise.
    private var listKind: MediaKind {
        if media.playlistPrefersAudio { return .audio }
        return media.request.map { MediaURL.siteKind($0.pageURL) } ?? .unknown
    }

    /// What the selected entries become: tracks for an audio format, videos otherwise.
    private var downloadKind: MediaKind { isAudio ? .audio : .video }

    private static func isAudioCap(_ cap: QualityCap) -> Bool { cap == .audioM4A || cap == .audioMP3 }

    /// Compatible follows the remembered setting from the first frame, like the single-video pane.
    init(list: PlaylistInfo, pageHost: String?, initialCompatible: Bool) {
        self.list = list
        self.pageHost = pageHost
        _compatible = State(initialValue: initialCompatible)
    }

    /// "English (default)", "Original", then the Mac's preferred languages (and the remembered one, if it's another).
    private var audioLanguageChoices: [(code: String, title: String)] {
        func base(_ code: String) -> String { String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }
        var choices: [(code: String, title: String)] = [(FormatCatalog.defaultAudioLanguage, "English (default)"),
                                                        (FormatCatalog.originalAudioLanguage, "Original")]
        var seen: Set<String> = ["en"]
        for code in Locale.preferredLanguages.map(base) + [audioLanguage] where !code.isEmpty && code != FormatCatalog.originalAudioLanguage {
            guard seen.insert(base(code)).inserted else { continue }
            choices.append((code, Locale.current.localizedString(forLanguageCode: code) ?? code))
        }
        return choices
    }

    private var audioLanguageTitle: String {
        audioLanguageChoices.first { $0.code == audioLanguage }?.title ?? audioLanguage
    }
    private var folder: URL { folderOverride ?? (isAudio ? media.settings.audioFolder : media.settings.videoFolder) }

    var body: some View {
        let count = list.entries.count
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Download playlist", subtitle: pageHost)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
            HStack(spacing: 14) {
                Image(systemName: listKind == .audio ? "music.note.list" : "list.and.film")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.tint(.video).foreground)
                    .frame(width: 46, height: 46)
                    .background(Theme.tint(.video).background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(list.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                    Text(listKind.count(count)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Theme.tile.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            // One quality and audio language for every entry, right under the header; wraps when it doesn't fit.
            FlowLayout(spacing: 10) {
                qualityChip
                audioLanguageChip
                if !isAudio {
                    CompactSwitch(title: "Compatible (MP4 / H.264)", isOn: $compatible)
                        .help("Prefer H.264 video and AAC audio in MP4, which QuickTime and every Apple device play.")
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                GroupLabel(title: "\(selection.count) of \(count) selected") {
                    HStack(spacing: 2) {
                        Button("Select all") { selection = Set(list.entries.indices) }
                            .disabled(selection.count == count)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Button("Select none") { selection = [] }
                            .disabled(selection.isEmpty)
                    }
                    .buttonStyle(.capsule(.text, height: 22, fontSize: 12))
                }
                ScrollView {
                    PlaylistChecklist(entries: list.entries, resolved: media.resolvedEntries, resolving: media.resolvingRows,
                                      selection: $selection)
                }
                // The rows on screen, from the scroll offset (rows are a fixed height; lazily built rows never
                // report leaving the screen). The title resolver reads these first.
                .onScrollGeometryChange(for: ClosedRange<Int>.self, of: { geometry in
                    // The visible part of the content, clamped to the content (an overscroll or a first layout
                    // before the list has its real height must not count rows that aren't there).
                    let height = PlaylistChecklist.rowHeight
                    let rect = geometry.visibleRect
                    let minY = min(max(0, rect.minY), geometry.contentSize.height)
                    let maxY = min(max(minY, rect.maxY), geometry.contentSize.height)
                    let top = Int(minY / height)
                    let bottom = max(top, Int((maxY - 1) / height))
                    return top...bottom
                }, action: { _, rows in
                    visibleRows = Set(rows.clamped(to: 0...max(0, count - 1)))
                })
                .scrollIndicators(.automatic)
            }
            .frame(maxHeight: .infinity)
            // Pinned at the bottom, with the buttons.
            FormGroup {
                FolderRow(folder: folder) { folderOverride = $0 }
            }
            Footer {
                if confirmingLarge {
                    // Many entries: one more click, so a 444-track set isn't queued by accident.
                    Text("Add \(downloadKind.count(selection.count))?")
                        .font(.system(size: 13, weight: .semibold))
                } else if !media.hasFFmpeg, cap != .audioM4A {
                    // Only original M4A audio is saved as is; video parts are joined and MP3 is converted by ffmpeg.
                    // Download stays available: each entry is checked when it's added, and one that needs ffmpeg is reported.
                    FFmpegInstallLink(model: FFmpegInstallLink.Model(progress: media.ffmpegProgress) { media.installFFmpeg() })
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            } buttons: {
                if confirmingLarge {
                    Button("Cancel", role: .cancel) { confirmingLarge = false }
                        .buttonStyle(.capsule(.secondary, height: 36, fontSize: 13))
                        .keyboardShortcut(.cancelAction)
                    Button("Add") { download() }
                        .buttonStyle(.capsule(.primary, height: 36, fontSize: 13))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { media.close() }
                        .buttonStyle(.capsule(.secondary, height: 36, fontSize: 13))
                        .keyboardShortcut(.cancelAction)
                    Button("Download \(downloadKind.count(selection.count))") {
                        if selection.count > Self.largeBatch { confirmingLarge = true } else { download() }
                    }
                    .buttonStyle(.capsule(.primary, height: 36, fontSize: 13))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            selection = Set(list.entries.indices)
            audioLanguage = media.settings.audioLanguage
            let remembered = QualityCap.maxHeight(media.settings.maxHeight)
            cap = media.playlistPrefersAudio ? .audioM4A : (Self.caps.contains { $0.0 == remembered } ? remembered : .best)
        }
        // Music (an audio site, or a first entry without video) defaults to Audio · M4A unless the user chose a quality.
        .onChange(of: media.playlistPrefersAudio) { _, audio in
            if audio, !choseCap { cap = .audioM4A }
        }
        .onChange(of: selection) { _, _ in confirmingLarge = false }
        .onChange(of: visibleRows) { _, rows in media.setVisibleRows(rows) }
        .onChange(of: compatible) { _, value in media.settings.compatible = value }
    }

    private var qualityTitle: String { Self.caps.first { $0.0 == cap }?.1 ?? "Best" }

    private var qualityChip: some View {
        LabeledChip(label: "Quality") {
            Menu {
                ForEach(Self.caps.indices, id: \.self) { index in
                    let (value, title) = Self.caps[index]
                    // The video caps, then a divider, then the audio formats.
                    if index > 0, Self.isAudioCap(value), !Self.isAudioCap(Self.caps[index - 1].0) { Divider() }
                    Toggle(title, isOn: Binding(get: { cap == value }, set: { _ in
                        cap = value
                        choseCap = true
                    }))
                }
            } label: {
                ChipLabel(text: qualityTitle, maxTextWidth: chipTextWidth)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Quality")
            .accessibilityValue(qualityTitle)
        }
    }

    private var audioLanguageChip: some View {
        LabeledChip(label: "Audio") {
            Menu {
                ForEach(audioLanguageChoices, id: \.code) { choice in
                    Toggle(choice.title, isOn: Binding(get: { audioLanguage == choice.code }, set: { _ in audioLanguage = choice.code }))
                }
            } label: {
                ChipLabel(text: audioLanguageTitle, maxTextWidth: chipTextWidth)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Audio language")
            .accessibilityValue(audioLanguageTitle)
            .help("For videos with several audio tracks. A video without this language keeps its original audio.")
        }
    }

    private func download() {
        let rows = list.entries.indices.filter(selection.contains)
        if case .maxHeight(let height) = cap { media.settings.maxHeight = height }
        // Entries that turn out to be audio only go to the audio folder, unless the user chose a folder here.
        let audioFolder: URL? = folderOverride == nil && !isAudio ? media.settings.audioFolder : nil
        media.downloadPlaylist(rows: rows, cap: cap, compatible: compatible, audioLanguage: audioLanguage, folder: folder,
                               audioFolder: audioFolder)
    }
}
