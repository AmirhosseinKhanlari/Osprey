import SwiftUI

struct StatusPill: View {
    let status: ItemStatus

    var body: some View {
        let colors = Theme.pill(status)
        Text(status.label)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(colors.foreground)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(colors.background, in: Capsule())
    }
}
