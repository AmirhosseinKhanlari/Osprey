import SafariServices
import OspreyBridge
import SwiftUI

/// Shown once: Safari extensions must be enabled by the user in Safari's settings.
struct SafariSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn on Osprey in Safari").font(.system(size: 17, weight: .semibold))
            Text("Safari keeps extensions off until you enable them. Open Safari Settings → Extensions, tick Osprey, and allow it on all websites so it can hand downloads over.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Later") { dismiss() }
                Button("Open Safari Settings") {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: BridgeLocation.safariExtensionIdentifier) { _ in }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
