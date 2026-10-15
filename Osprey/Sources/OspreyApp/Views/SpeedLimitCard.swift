import SwiftUI

/// The sidebar's speed limit: a switch for `DownloadManager.speedLimitMBps` and a slider for its value.
struct SpeedLimitCard: View {
    @Environment(DownloadManager.self) private var manager
    /// The slider's value, kept while the limit is off.
    @AppStorage("speedLimitValue") private var value = 20.0

    var body: some View {
        let isOn = manager.speedLimitMBps != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("Speed limit").font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: "gauge.with.needle").foregroundStyle(Theme.accent)
                }
                .labelStyle(.titleAndIcon)
                Spacer(minLength: 4)
                Toggle("Speed limit", isOn: Binding(
                    get: { isOn },
                    set: { manager.speedLimitMBps = $0 ? value : nil }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { value },
                    set: { newValue in
                        value = newValue
                        if manager.speedLimitMBps != nil { manager.speedLimitMBps = newValue }
                    }), in: 1...100, step: 1)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(!isOn)
                    .accessibilityLabel("Speed limit")
                    .accessibilityValue("\(Int(value)) megabytes per second")
                Text("\(Int(value)) MB/s")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 58, alignment: .trailing)
            }
            // Both captions are laid out so the card keeps the taller one's height: it sits at the bottom
            // of the sidebar, so a caption that wraps differently would make the whole card jump.
            ZStack(alignment: .topLeading) {
                caption("Per download. New connections stop at 85% of the cap.", visible: isOn)
                caption("Off · full speed on all connections.", visible: !isOn)
            }
        }
        .padding(12)
        .background(Theme.cardGlass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func caption(_ text: String, visible: Bool) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
    }
}
