import AppKit
import OspreyMedia
import SwiftUI

/// One row of the design's grouped form: a label on the left, a control on the right.
struct FormRow<Control: View>: View {
    let title: String
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

/// The grouped form's rounded white container.
struct FormGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.group, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke.opacity(0.75)))
    }
}

/// A value on a soft chip, as the design draws its pop-up buttons ("Applications ⌄").
struct ChipLabel: View {
    let text: String
    var symbol: String?
    var showsChevron = true
    /// The longest the text may get before it truncates (nil: no limit). Set from the container, never the content.
    var maxTextWidth: CGFloat?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
            // Shortened here, not by a flexible frame: a pop-up button sizes itself from its label and would
            // otherwise collapse the text to "…".
            Text(Self.fitted(text, maxWidth: maxTextWidth))
                .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// `text`, or its longest prefix plus "…" that fits `maxWidth` in the chip's 13 pt system font.
    static func fitted(_ text: String, maxWidth: CGFloat?) -> String {
        let font = NSFont.systemFont(ofSize: 13)
        return TextFit.truncate(text, maxWidth: maxWidth.map(Double.init)) {
            Double(($0 as NSString).size(withAttributes: [.font: font]).width)
        }
    }
}

/// "− 8 +" on a chip; steps through `values`.
struct ChipStepper: View {
    let label: String
    let values: [Int]
    @Binding var value: Int

    var body: some View {
        let index = values.firstIndex(of: value) ?? values.firstIndex { $0 >= value } ?? 0
        HStack(spacing: 2) {
            step("minus", "Fewer \(label)", enabled: index > 0) { value = values[index - 1] }
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 30)
                .accessibilityHidden(true)
            step("plus", "More \(label)", enabled: index < values.count - 1) { value = values[index + 1] }
        }
        .padding(2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label.capitalized)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index < values.count - 1 { value = values[index + 1] }
            case .decrement: if index > 0 { value = values[index - 1] }
            @unknown default: break
            }
        }
    }

    private func step(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(help)
    }
}

/// The design's two-option segmented control: a chip track with a raised white selected segment.
struct ChipSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.segment)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
