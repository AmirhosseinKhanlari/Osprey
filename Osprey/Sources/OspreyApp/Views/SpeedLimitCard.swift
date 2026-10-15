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
            // Always two lines tall, whatever the text or the sidebar's width: the card sits at the bottom of the
            // sidebar, so a caption whose height followed its wrapping would make the card jump, and while the window
            // is resized it would change the sidebar's minimum height on every pass (an AppKit layout loop that aborts).
            // The hidden two-line placeholder never wraps, so its height (and the card's) doesn't depend on the width.
            ZStack(alignment: .topLeading) {
                Text(verbatim: "X\nX")
                    .hidden()
                    .accessibilityHidden(true)
                Text(isOn ? "Per download. New connections stop at 85% of the cap." : "Off · full speed on all connections.")
                    .lineLimit(2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.cardGlass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}
