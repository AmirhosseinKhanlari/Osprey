import SwiftUI

/// A category's symbol on its tinted rounded tile.
struct CategoryTile: View {
    let category: Category
    var size: CGFloat = 38
    var cornerRadius: CGFloat = 10
    var symbolSize: CGFloat = 17

    var body: some View {
        let tint = Theme.tint(category)
        Image(systemName: category.symbol)
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(tint.foreground)
            .frame(width: size, height: size)
            .background(tint.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}
