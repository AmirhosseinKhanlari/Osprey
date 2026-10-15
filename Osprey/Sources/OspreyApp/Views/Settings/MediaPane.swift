import AppKit
import OspreyIntegration
import OspreyMedia
import SwiftUI

/// Settings › Media: where videos and audio go, the picker's default, the browsers' video button, and the state of
/// yt-dlp and ffmpeg with Update and Install.
struct MediaPane: View {
    @Environment(MediaCoordinator.self) private var media
    @Environment(ToolStatus.self) private var tools
    @State private var videoButton = IntegrationSettingsStore().settings.videoButton

    var body: some View {
        @Bindable var settings = media.settings
        SettingsSection(title: "Folders") {
            MediaFolderRow(title: "Videos", folder: settings.videoFolder) { settings.videoFolder = $0 }
            MediaFolderRow(title: "Audio", folder: settings.audioFolder, showsDivider: false) { settings.audioFolder = $0 }
        }
        SettingsSection(title: "Downloads") {
            SettingsToggleRow(title: "Compatible (MP4/H.264) by default",
                              help: "The picker starts with formats QuickTime and Photos play. Off: the best quality, often VP9 or AV1.",
                              isOn: $settings.compatible)
            SettingsToggleRow(title: "Show download button over videos",
                              help: "Chrome and Safari show a Download button on videos you can save.",
                              isOn: $videoButton, showsDivider: false)
        }
        .onChange(of: videoButton) { _, newValue in
            // Change only this key: the Browser integration pane owns the rest.
            let store = IntegrationSettingsStore()
            var current = store.settings
            current.videoButton = newValue
            store.settings = current
        }
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: "Tools") {
                ToolRow(tool: .ytdlp)
                ToolRow(tool: .ffmpeg, showsDivider: false)
            }
            Text("Osprey keeps its own yt-dlp and checks for a new version once a day. Copies installed with Homebrew are used as they are and never changed. ffmpeg joins video and audio; without it the picker still lists every format, marks the ones that need ffmpeg, and offers to install it.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
        .task {
            tools.refresh()
            // Keep "Last checked" and the retry countdown current while the pane is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                tools.refreshRecords()
            }
        }
    }
}

/// A folder setting: the folder as breadcrumbs on a chip; clicking opens a folder chooser.
private struct MediaFolderRow: View {
    let title: String
    let folder: URL
    var showsDivider = true
    let choose: (URL) -> Void

    var body: some View {
        FormRow(title: title, showsDivider: showsDivider) {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose"
                panel.directoryURL = folder
                if panel.runModal() == .OK, let url = panel.url { choose(url) }
            } label: {
                ChipLabel(text: Format.crumbs(folder), symbol: "folder", showsChevron: false)
            }
            .buttonStyle(.plain)
            .help(Format.path(folder))
            .accessibilityLabel("\(title) folder")
            .accessibilityValue(Format.path(folder))
            .accessibilityHint("Choose another folder")
        }
    }
}

/// One tool: its name and version, where it comes from, the last update check (yt-dlp), and Update or Install.
private struct ToolRow: View {
    @Environment(ToolStatus.self) private var status
    let tool: MediaTool
    var showsDivider = true

    private var name: String { tool == .ytdlp ? "yt-dlp" : "ffmpeg" }

    var body: some View {
        let row = status.row(tool)
        HStack(spacing: 12) {
            Image(systemName: tool == .ytdlp ? "arrow.down.doc" : "film.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .medium))
                    if status.loaded { SourceBadge(source: row.source) }
                }
                Text(subtitle(row))
                    .font(.system(size: 11.5))
                    .foregroundStyle(status.error(tool) == nil ? Theme.textSecondary : Theme.error)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            action(row)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    /// "Version 2026.10.10 · Last checked 3 hr. ago", or the last error.
    private func subtitle(_ row: ToolStatus.Row) -> String {
        if let error = status.error(tool) { return error }
        guard status.loaded else { return "Checking…" }
        var bits: [String] = []
        if row.source == nil {
            bits.append(tool == .ffmpeg ? "Needed to join video and audio" : "Installed on first use")
        } else {
            bits.append(row.version.map { "Version \($0)" } ?? "Version unknown")
        }
        if tool == .ytdlp {
            bits.append("Last checked " + (status.lastUpdateCheck.map { Format.ago($0) } ?? "Never"))
        }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func action(_ row: ToolStatus.Row) -> some View {
        if status.isBusy(tool) {
            HStack(spacing: 8) {
                if let fraction = status.fraction(tool) {
                    ProgressView(value: fraction).frame(width: 90)
                    Text("\(Int(fraction * 100))%").font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(Theme.textSecondary).frame(width: 34, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text(row.source == .managed ? "Updating…" : "Installing…").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.source == .managed ? "Updating \(name)" : "Installing \(name)")
            .accessibilityValue(status.fraction(tool).map { "\(Int($0 * 100)) percent" } ?? "")
        } else if let kind = buttonKind(row) {
            if let remaining = status.backoffRemaining(tool) {
                let minutes = max(1, Int((remaining / 60).rounded(.up)))
                Text("Retrying in \(minutes) min")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("\(name): the last attempt failed. You can try again in \(minutes) minutes.")
            } else {
                Button(kind == .update ? "Update now" : "Install") {
                    if kind == .update { status.updateYtDlp() } else { status.install(tool) }
                }
                .buttonStyle(.capsule(.secondary))
                .accessibilityLabel(kind == .update ? "Update \(name) now" : "Install \(name)")
                .help(kind == .update ? "Download the latest yt-dlp now"
                      : (tool == .ffmpeg ? "Download a verified ffmpeg build into Osprey's Tools folder"
                                         : "Download Osprey's own, self-updating yt-dlp"))
            }
        }
    }

    private enum ButtonKind { case update, install }

    /// Update: Osprey's own yt-dlp. Install: a missing ffmpeg, or yt-dlp when only Homebrew's (or none) is there.
    /// A Homebrew or managed ffmpeg gets no button: Homebrew's is never changed and the managed build is pinned.
    private func buttonKind(_ row: ToolStatus.Row) -> ButtonKind? {
        guard status.loaded else { return nil }
        switch (tool, row.source) {
        case (.ytdlp, .managed): return .update
        case (.ytdlp, _): return .install
        case (.ffmpeg, nil): return .install
        case (.ffmpeg, _): return nil
        }
    }
}

/// "Managed", "Homebrew" or "Not installed" on a small capsule.
private struct SourceBadge: View {
    let source: ToolLocation.Source?

    var body: some View {
        let (text, foreground, background): (String, Color, Color) = switch source {
        case .managed: ("Managed", Color(light: 0x16733F, dark: 0x4FD88A),
                        Color(light: 0x18834A, dark: 0x3CCF7C, lightAlpha: 0.12, darkAlpha: 0.16))
        case .homebrew: ("Homebrew", Color(light: 0x9A5200, dark: 0xFFB35C),
                         Color(light: 0xC46A00, dark: 0xFFA53D, lightAlpha: 0.12, darkAlpha: 0.16))
        case nil: ("Not installed", Theme.textSecondary, Theme.chip)
        }
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .accessibilityLabel("Source: \(text)")
    }
}
