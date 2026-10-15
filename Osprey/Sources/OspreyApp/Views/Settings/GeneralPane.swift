import SwiftUI

struct GeneralPane: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("maxConnections") private var maxConnections = 8

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
    }
}
