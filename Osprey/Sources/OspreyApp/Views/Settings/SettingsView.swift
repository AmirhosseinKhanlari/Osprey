import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The Settings panes. Only panes with real settings are listed.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case browsers = "Browser integration"
    case media = "Media"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .browsers: "globe"
        case .media: "film.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: Color(light: 0x8E8E93, dark: 0x8E8E93)
        case .browsers: Color(light: 0x1F9D55, dark: 0x1F9D55)
        case .media: Color(light: 0x7D4CDB, dark: 0x7D4CDB)
        }
    }
}

/// Settings: a glass sidebar of panes beside the selected pane's content.
struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = SettingsPane.browsers

    private static let contentBackground = Color(light: 0xF7F7F9, dark: 0x1E1E22, lightAlpha: 0.92, darkAlpha: 0.92)

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $pane)
            VStack(alignment: .leading, spacing: 0) {
                // The pane's title sits in the title bar band, level with the window controls.
                // An opaque header drawn above the scroll view: scrolled content passes under it
                // and never shows through the title.
                Text(pane.rawValue)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.2)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 28)
                    .padding(.top, 32)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        ZStack {
                            WindowBackdrop()
                            Self.contentBackground
                        }
                    }
                    .zIndex(1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch pane {
                        case .general: GeneralPane()
                        case .browsers: BrowserIntegrationPane()
                        case .media: MediaPane()
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectHiddenIfAvailable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
            .background(Self.contentBackground.ignoresSafeArea())
        }
        .background(WindowBackdrop().ignoresSafeArea())
        .frame(width: 900, height: 592)   // with the title bar, the mockup's 900 × 680
        .toolbar {
            // A toolbar gives the Settings window its tall title bar, so the window controls sit
            // inside the sidebar panel as in the main window.
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(Theme.accent)
    }
}

/// The pane list. It reads and writes the selection only through `selection`, and each row gets its
/// selected state as a value: a `ForEach` row closure that reads the selection itself is not run
/// again when the selection changes, so its highlight would stay on an earlier pane.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        let current = selection
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { row($0, isSelected: $0 == current) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 66)   // the window controls sit on the panel
        .padding(.bottom, 14)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 14, fill: Theme.glass)
        .padding([.leading, .top, .bottom], 8)
        .ignoresSafeArea(.container, edges: .top)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let panes = SettingsPane.allCases
        let index = panes.firstIndex(of: selection) ?? 0
        selection = panes[min(max(index + offset, 0), panes.count - 1)]
        return .handled
    }

    private func row(_ item: SettingsPane, isSelected selected: Bool) -> some View {
        Button { selection = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(item.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A titled group of settings rows on a white card.
struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(Theme.group, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.75)))
        }
    }
}

/// A setting with a title, a line of help, and a switch.
struct SettingsToggleRow: View {
    let title: String
    let help: String
    @Binding var isOn: Bool
    var showsDivider = true

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(help).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.settingsSwitch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

private extension View {
    /// The pane scrolls below its own title, so it needs no blur under the title bar.
    @ViewBuilder
    func scrollEdgeEffectHiddenIfAvailable() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
