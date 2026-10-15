import SwiftUI

/// Total speed now, what is left, and the last 60 seconds as an area chart.
struct ThroughputCard: View {
    /// One sample per second, oldest first.
    let history: [Double]
    let current: Double
    let connections: Int
    let remaining: Int64
    let active: Int

    var body: some View {
        let parts = Format.speedParts(current)
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Throughput").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 10)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.value)
                        .font(.system(size: 46, weight: .semibold))
                        .tracking(-1.2)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(parts.unit).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total speed \(Format.speed(current))")
                Spacer(minLength: 10)
                FlowLayout(spacing: 6) {
                    Chip(text: connections == 1 ? "1 connection" : "\(connections) connections")
                    if remaining > 0 {
                        Chip(text: "\(Format.bytes(remaining)) left")
                        let eta = Format.eta(remaining: remaining, speed: current)
                        if eta != "—" { Chip(text: "≈ \(eta)") }
                    } else if active == 0 {
                        Chip(text: "Idle")
                    }
                }
            }
            .frame(width: 230, alignment: .leading)
            VStack(spacing: 6) {
                ThroughputChart(values: Array(history.suffix(60)))
                    .frame(height: 104)
                HStack {
                    Text("60 s ago")
                    Spacer()
                    Text("Now")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Throughput over the last 60 seconds")
            .accessibilityValue("Now \(Format.speed(current))")
        }
        .frame(height: 124)
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .surfaceCard()
    }
}

/// The throughput line with an accent gradient fill, three grid lines and a dot at "now".
struct ThroughputChart: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = points(in: size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    for fraction in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: 0, y: size.height * fraction))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    }
                }
                .stroke(Theme.grid, lineWidth: 1)
                if let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    Circle().fill(Theme.accent).frame(width: 8, height: 8).position(last)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        // Headroom above the peak; at least 1 MB/s so an idle chart stays flat at the bottom.
        let top = max(values.max() ?? 0, 1_000_000) * 1.15
        let inset: CGFloat = 4   // keep the 2.2 pt line and the dot inside the frame
        return values.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: inset + (size.height - inset * 2) * (1 - CGFloat(value / top)))
        }
    }
}
