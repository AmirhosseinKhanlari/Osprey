import AppKit
import OspreyMedia
import SwiftUI

/// The video picker: a fixed 560×640 sheet on the main window, in the Add URL sheet's style. It shows the
/// coordinator's state: setting up yt-dlp, looking the page up, a single video, a playlist, or an error.
struct MediaPickerSheet: View {
    @Environment(MediaCoordinator.self) private var media

    static let size = CGSize(width: 560, height: 640)

    var body: some View {
        Group {
            switch media.state {
            case .idle, .loading:
                StatusPane(symbol: nil, title: "Looking up the media…", message: lookupSubtitle) {
                    cancelButton("Cancel")
                }
            case .settingUpTools(let fraction):
                StatusPane(symbol: "arrow.down.circle", title: "Setting up the media downloader…",
                           message: "Osprey fetches yt-dlp once and keeps it up to date.") {
                    cancelButton("Cancel")
                } accessory: {
                    Group {
                        if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                    }
                    .frame(width: 260)
                }
            case .error(let error):
                StatusPane(symbol: error == .drmProtected ? "lock.fill" : "exclamationmark.triangle.fill",
                           title: error == .drmProtected ? "This media is protected" : "Couldn’t get media from this page",
                           message: error.userMessage, isError: true) {
                    cancelButton("Close")
                    Button("Retry") { media.retry() }
                        .buttonStyle(.capsule(.primary, height: 36, fontSize: 13))
                        .keyboardShortcut(.defaultAction)
                }
            case .single(let info):
                SingleVideoPane(info: info, pageHost: host, initialMode: media.settings.pickerMode,
                                initialCompatible: media.settings.compatible).id(media.request?.id)
            case .playlist(let list):
                PlaylistPane(list: list, pageHost: host, initialCompatible: media.settings.compatible).id(media.request?.id)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(Theme.accent)
    }

    private var host: String? { media.request?.pageURL.host(percentEncoded: false) }

    private var lookupSubtitle: String {
        [media.request?.title?.nonEmpty, host].compactMap { $0 }.joined(separator: " · ")
    }

    private func cancelButton(_ title: String) -> some View {
        Button(title, role: .cancel) { media.close() }
            .buttonStyle(.capsule(.secondary, height: 36, fontSize: 13))
            .keyboardShortcut(.cancelAction)
    }
}

// MARK: - Shared pieces

/// The sheet's title block, as in Add URL ("New download" / its subtitle).
struct SheetHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 19, weight: .bold)).tracking(-0.2)
            if let subtitle {
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small label above a group ("Quality", "Audio only").
struct GroupLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Spacer()
            trailing
        }
    }
}

extension GroupLabel where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// The DRM notice.
struct FolderRow: View {
    let folder: URL
    var showsDivider = false
    let choose: (URL) -> Void

    var body: some View {
        FormRow(title: "Save to", showsDivider: showsDivider) {
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
            .accessibilityLabel("Save to \(Format.path(folder))")
        }
    }
}

/// The sheet's bottom row: an optional note on the left, buttons on the right.
struct Footer<Leading: View, Buttons: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 8)
            buttons
        }
        .padding(.top, 2)
    }
}

/// Loading, setting up, and error: a centered message with buttons at the bottom.
private struct StatusPane<Buttons: View, Accessory: View>: View {
    let symbol: String?
    let title: String
    let message: String
    var isError = false
    @ViewBuilder var buttons: Buttons
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isError ? Theme.error : Theme.accent)
                        .frame(width: 58, height: 58)
                        .background(isError ? Theme.errorSoft : Theme.accentSoft, in: Circle())
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.regular)
                }
                Text(title).font(.system(size: 16, weight: .bold))
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 400)
                }
                accessory
            }
            Spacer()
            Footer { EmptyView() } buttons: { buttons }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }
}

extension StatusPane where Accessory == EmptyView {
    init(symbol: String?, title: String, message: String, isError: Bool = false, @ViewBuilder buttons: () -> Buttons) {
        self.init(symbol: symbol, title: title, message: message, isError: isError, buttons: buttons) { EmptyView() }
    }
}
