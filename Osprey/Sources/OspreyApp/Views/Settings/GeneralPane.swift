import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("maxConnections") private var maxConnections = 8
    @State private var openAtLogin = false
    @State private var needsApproval = false
    @State private var loginError: String?
    private let loginItem: any LoginItemControlling = LoginItem()

    var body: some View {
        SettingsSection {
            FormRow(title: "Appearance") {
                ChipSegments(options: Appearance.allCases.map { ($0, $0.rawValue) }, selection: $appearance)
            }
            FormRow(title: "Default connections", showsDivider: false) {
                ChipStepper(label: "connections", values: [1, 2, 4, 8, 12, 16, 24, 32], value: $maxConnections)
            }
        }
        Text("New downloads and browser captures open up to this many connections. Each download starts with one and doubles every second while every connection is receiving data.")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)
        SettingsSection {
            SettingsToggleRow(title: "Open at login",
                              help: "Osprey opens when you log in, so scheduled queues still start after a restart.",
                              isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }), showsDivider: false)
                .disabled(!CaptureNotifier.isAvailable)       // a bare `swift run` build can't be a login item
        }
        .onAppear(perform: readLoginItem)
        // Last in the pane, so these notes never push anything else down.
        if needsApproval {
            HStack(spacing: 8) {
                Text("Allow Osprey in System Settings › General › Login Items.")
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 4)
        }
        if let loginError {
            Text(loginError)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private func readLoginItem() {
        openAtLogin = loginItem.isEnabled || loginItem.needsApproval
        needsApproval = loginItem.needsApproval
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = "Couldn’t change Open at login: \(error.localizedDescription)"
        }
        readLoginItem()
    }
}
