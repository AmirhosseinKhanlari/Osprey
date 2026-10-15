import AppKit
import SafariServices
import OspreyBridge
import OspreyIntegration
import SwiftUI

struct BrowserIntegrationPane: View {
    @State private var integration = IntegrationSettingsStore().settings
    @State private var browsers: [BrowserStatus] = BrowserStatus.chromiumBrowsers()

    var body: some View {
        SettingsSection {
            SettingsToggleRow(title: "Take over downloads from Chrome and Safari",
                              help: "Matching downloads go to Osprey; anything it can’t take stays with the browser.",
                              isOn: $integration.enabled)
            SettingsToggleRow(title: "Show a progress window",
                              help: "A small window shows each download a browser hands over. Off: a notification.",
                              isOn: $integration.showProgressWindow)
            SettingsToggleRow(title: "Also in private windows",
                              help: "Off: private-window downloads stay in the browser.",
                              isOn: $integration.captureInPrivate, showsDivider: false)
        }
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: "Browsers") {
                ForEach(browsers) { browser in
                    BrowserRow(status: browser, showsDivider: browser.id != browsers.last?.id)
                }
            }
            HStack(spacing: 8) {
                Button("Repair Chrome helper") {
                    CaptureService.installChromeHostManifests()
                    Task { await refresh() }
                }
                .help("Rewrite the native-messaging helper for every installed Chrome-family browser")
                Button("Open Safari Extension Settings…") {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: BridgeLocation.safariExtensionIdentifier) { _ in }
                }
            }
            .buttonStyle(.capsule(.secondary))
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("File types to take over")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            FileTypeChips(extensions: $integration.extensions)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.group, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.75)))
            Text("`*` matches any ending (r0* covers r00, r01…). Hold ⌥ Option while clicking a link to let the browser download it instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
        .onChange(of: integration) { _, newValue in IntegrationSettingsStore().settings = newValue }
        .task { await refresh() }
        // Safari's switch lives in Safari: check again whenever the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let safari = await BrowserStatus.safari()
        let chromium = BrowserStatus.chromiumBrowsers()
        // Chrome, Safari, then the other Chromium browsers, Chromium itself last.
        let others = chromium.dropFirst().sorted { ($0.name == "Chromium" ? 1 : 0) < ($1.name == "Chromium" ? 1 : 0) }
        browsers = [chromium.first].compactMap { $0 } + [safari] + others
    }
}

private struct BrowserRow: View {
    let status: BrowserStatus
    let showsDivider: Bool

    var body: some View {
        let color: Color = status.state.isGood ? Theme.green
            : (status.state.needsAttention ? Theme.orange : Theme.textTertiary)
        HStack(spacing: 12) {
            Image(systemName: status.name == "Safari" ? "safari" : "globe")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(status.name).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(status.state.isGood ? Theme.greenBadge : color.opacity(0.85)).frame(width: 7, height: 7)
                Text(status.state.label).font(.system(size: 12)).foregroundStyle(color)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The file types as removable chips, with an "Add type…" field. The first rows show by default;
/// "+ N more" shows the rest.
struct FileTypeChips: View {
    @Binding var extensions: [String]
    @State private var showsAll = false
    @State private var draft = ""

    private let collapsedCount = 14

    var body: some View {
        let shown = showsAll ? extensions : Array(extensions.prefix(collapsedCount))
        FlowLayout(spacing: 6) {
            ForEach(shown, id: \.self) { ext in chip(ext) }
            if extensions.count > collapsedCount {
                Button { withAnimation(.easeOut(duration: 0.2)) { showsAll.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(showsAll ? "Show less" : "+ \(extensions.count - collapsedCount) more")
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.chip, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(showsAll ? "Show only the first file types" : "Show every file type")
            }
            TextField("Add a file type", text: $draft, prompt: Text("Add type…"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(width: 110, height: 26)
                .overlay(Capsule().strokeBorder(Theme.textTertiary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .onSubmit(add)
        }
    }

    private func chip(_ ext: String) -> some View {
        HStack(spacing: 4) {
            Text(ext).font(.system(size: 12, weight: .semibold))
            Button {
                extensions.removeAll { $0 == ext }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(ext)")
        }
        .foregroundStyle(Color(light: 0x0A5BD6, dark: 0x7FB2FF))
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 26)
        .background(Theme.accentSoft, in: Capsule())
    }

    /// Adds whatever was typed (spaces or commas separate several), skipping ones already listed.
    private func add() {
        let new = IntegrationSettings.parseExtensions(draft).filter { !extensions.contains($0) }
        if !new.isEmpty { extensions.append(contentsOf: new) }
        draft = ""
    }
}
