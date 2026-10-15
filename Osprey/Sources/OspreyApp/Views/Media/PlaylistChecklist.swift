import OspreyMedia
import SwiftUI

/// The playlist's entries with a checkbox each. Selection is by position: a playlist may list a video twice.
struct PlaylistChecklist: View {
    let entries: [PlaylistEntry]
    /// Real titles (or failures) read after the list arrived, by row.
    var resolved: [Int: ResolvedEntry] = [:]
    /// Rows whose real title is being read right now.
    var resolving: Set<Int> = []
    @Binding var selection: Set<Int>

    /// Every row is this tall, so the rows on screen follow from the scroll offset.
    static let rowHeight: CGFloat = 40

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(entries.indices, id: \.self) { index in
                row(index)
            }
        }
        .background(Theme.group, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke.opacity(0.75)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ index: Int) -> some View {
        let entry = entries[index]
        let isOn = selection.contains(index)
        // Flat SoundCloud entries have no title: a name guessed from the link (marked "≈", in secondary text), else
        // "Track N", until the title resolver reads the real one.
        let placeholder = entry.listTitle(at: index)
        let state = resolved[index]
        let known: (title: String, duration: Double?)? = {
            if case .title(let title, let duration)? = state { return (title, duration) }
            return nil
        }()
        let hasOwnTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let duration = known?.duration ?? entry.duration
        return HStack(spacing: 12) {
            CheckBox(isOn: isOn)
            Text("\(index + 1)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(minWidth: 18, alignment: .trailing)
            if known == nil, placeholder.isFromLink {
                Text("≈")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Name taken from the link. The real title is used when it downloads.")
                    .accessibilityLabel("approximately")
            }
            Text(known?.title ?? placeholder.text)
                .font(.system(size: 13))
                .foregroundStyle(known != nil || hasOwnTitle ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if resolving.contains(index) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("getting the title")
            } else if state == .protected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .help("Protected (DRM): it can't be downloaded.")
                    .accessibilityLabel("protected")
            } else if state == .failed {
                Text("couldn’t read")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Osprey couldn’t read this entry’s details. It is tried again when it downloads.")
            }
            Spacer(minLength: 8)
            if let duration, duration > 0, let clock = Format.clock(duration) {
                Text(clock)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .overlay(alignment: .bottom) {
            if index < entries.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 44) }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { toggle(index) }
    }

    private func toggle(_ index: Int) {
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }
}

/// The design's checkbox: an accent rounded square with a check when on.
struct CheckBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isOn ? Theme.accent : Theme.field)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.textTertiary.opacity(0.6), lineWidth: 1.5)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
