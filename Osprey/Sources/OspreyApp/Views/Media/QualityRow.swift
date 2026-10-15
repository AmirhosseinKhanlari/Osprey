import OspreyMedia
import SwiftUI

/// One choice in the video picker: a radio dot, the quality ("1080p60"), a codec badge ("H.264 · MP4"),
/// notes, and the estimated size ("~" when yt-dlp only guessed it).
struct QualityRow: View {
    let option: QualityOption
    let isSelected: Bool
    /// Show "Won't play in QuickTime" (video options only; QuickTime plays M4A and MP3).
    var warnsQuickTime = false
    /// ffmpeg is missing and this option needs it.
    var needsFFmpeg = false
    var ffmpegInstall: FFmpegInstallLink.Model?
    var showsDivider = true
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RadioDot(isOn: isSelected)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(option.title).font(.system(size: 13, weight: .semibold))
                    if !option.detail.isEmpty { Badge(text: option.detail) }
                }
                if warnsQuickTime || needsFFmpeg {
                    HStack(spacing: 10) {
                        if warnsQuickTime {
                            Label("Won’t play in QuickTime", systemImage: "play.slash")
                                .help("This format plays in apps like IINA or VLC, not in QuickTime Player.")
                        }
                        if needsFFmpeg, let ffmpegInstall { FFmpegInstallLink(model: ffmpegInstall) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .labelStyle(SmallIconLabelStyle())
                }
            }
            Spacer(minLength: 8)
            Text(Self.size(option))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 46)
        .background(isSelected ? Theme.accentSoft : .clear)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 44) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)            // AXPress (VoiceOver, automation) selects, like a click
    }

    /// "~160 MB", "412 MB", or "Size unknown" when yt-dlp gave nothing to estimate from.
    static func size(_ option: QualityOption) -> String {
        guard let bytes = option.estimatedBytes, bytes > 0 else { return "Size unknown" }
        return (option.estimateIsApproximate ? "~" : "") + Format.bytes(bytes)
    }
}

/// The design's radio: an accent ring with a dot when on.
struct RadioDot: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(isOn ? Theme.accent : Theme.textTertiary.opacity(0.6), lineWidth: isOn ? 5 : 1.5)
                .background(Circle().fill(isOn ? Color.white : Theme.field))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// A small capsule label ("H.264 · MP4").
struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Theme.chip, in: Capsule())
    }
}

/// "Needs ffmpeg — Install", or the install's progress.
struct FFmpegInstallLink: View {
    struct Model {
        /// nil when idle; `.some(nil)` while starting; the fraction once known.
        var progress: Double??
        var install: () -> Void
    }

    let model: Model

    var body: some View {
        HStack(spacing: 4) {
            if let progress = model.progress {
                ProgressView().controlSize(.mini)
                Text(progress.map { "Installing ffmpeg… \(Int(($0 * 100).rounded()))%" } ?? "Installing ffmpeg…")
            } else {
                Text("Needs ffmpeg —")
                Button("Install", action: model.install)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .fontWeight(.semibold)
                    .help("Download ffmpeg, which joins video and audio and converts to MP3.")
            }
        }
    }
}

struct SmallIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
