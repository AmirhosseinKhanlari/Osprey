import SwiftUI

extension View {
    /// A Liquid Glass panel on macOS 26 and later; a translucent material with a hairline before that.
    /// `fill` is the design's panel colour, laid inside the glass so the panel reads as light (or dark)
    /// as the mockup whatever is behind the window.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat, fill: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            background(fill ?? .clear, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            background(fill ?? .clear, in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.stroke))
        }
    }

    /// The design's near-opaque content card: surface fill, hairline and a soft shadow.
    func surfaceCard(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline))
            .shadow(color: Theme.shadow, radius: 15, y: 10)
    }
}

/// The design's wallpaper gradient (140°), anchored to the window rather than to the view, so the
/// sidebar, detail and inspector columns each draw their part of one continuous backdrop.
struct WindowBackdrop: View {
    /// The design's window size; the gradient's start and end points are placed for it.
    private static let canvas = CGSize(width: 1440, height: 900)

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let width = max(frame.width, 1)
            let height = max(frame.height, 1)
            // CSS 140deg over the canvas: from (201, -168) to (1239, 1068).
            LinearGradient(stops: [.init(color: Theme.wall[0], location: 0),
                                   .init(color: Theme.wall[1], location: 0.52),
                                   .init(color: Theme.wall[2], location: 1)],
                           startPoint: UnitPoint(x: (201 - frame.minX) / width, y: (-168 - frame.minY) / height),
                           endPoint: UnitPoint(x: (Self.canvas.width - 201 - frame.minX) / width,
                                               y: (Self.canvas.height + 168 - frame.minY) / height))
        }
        .accessibilityHidden(true)
    }
}
