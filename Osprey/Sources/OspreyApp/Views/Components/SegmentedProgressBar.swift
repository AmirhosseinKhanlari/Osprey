import OspreyEngine
import OspreyMedia
import SwiftUI

/// The design's progress bar: one rounded box per connection lane, each filled by its share of the file.
struct SegmentedProgressBar: View {
    let boxes: [ProgressBox]
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 2) {
            ForEach(boxes.indices, id: \.self) { index in
                let box = boxes[index]
                Capsule()
                    .fill(box.stalled ? Theme.orange.opacity(0.3) : Theme.track)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(box.stalled ? Theme.orange : color)
                                .frame(width: proxy.size.width * box.fraction)
                        }
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard !boxes.isEmpty else { return "" }
        let total = boxes.reduce(0) { $0 + $1.fraction } / Double(boxes.count)
        return "\(Int(total * 100)) percent, \(boxes.count) \(boxes.count == 1 ? "part" : "parts")"
    }
}

/// A media item's bar: each part's lanes (video, then audio) with a short divider between the parts. While the parts
/// are merged it is an indeterminate bar.
struct MediaProgressBar: View {
    let parts: [[ProgressBox]]
    var merging = false
    var color: Color = Theme.accent
    var height: CGFloat = 6
    /// Spoken with the bar, e.g. "Video 64 percent, audio 100 percent".
    var summary: String
    /// Spoken while merging: "Merging…" or "Converting…".
    var mergingText = "Merging…"

    var body: some View {
        Group {
            if merging {
                IndeterminateBar(color: color, height: height)
            } else {
                // Each part gets width in proportion to its lanes, after the dividers' share.
                GeometryReader { proxy in
                    let divider: CGFloat = 1.5, gap: CGFloat = 2
                    let dividers = CGFloat(max(parts.count - 1, 0)) * (divider + 2 * gap)
                    let lanes = CGFloat(max(parts.reduce(0) { $0 + max($1.count, 1) }, 1))
                    let available = max(proxy.size.width - dividers, 0)
                    HStack(spacing: gap) {
                        ForEach(parts.indices, id: \.self) { index in
                            if index > 0 {
                                Capsule().fill(Theme.textTertiary.opacity(0.55)).frame(width: divider, height: height + 4)
                            }
                            SegmentedProgressBar(boxes: parts[index], color: color, height: height)
                                .frame(width: available * CGFloat(max(parts[index].count, 1)) / lanes)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: height + 4)
            }
        }
        .frame(height: height + 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(merging ? mergingText : summary)
    }
}

/// A capsule with a highlight sliding across it, for work whose length isn't known (merging).
struct IndeterminateBar: View {
    var color: Color = Theme.accent
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Theme.track)
            .overlay(alignment: .leading) {
                if reduceMotion {
                    Capsule().fill(color.opacity(0.55))
                } else {
                    TimelineView(.animation) { context in
                        GeometryReader { proxy in
                            let period = 1.4
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                            let width = proxy.size.width * 0.35
                            Capsule()
                                .fill(color)
                                .frame(width: width)
                                .offset(x: -width + (proxy.size.width + width) * phase)
                        }
                    }
                }
            }
            .clipShape(Capsule())
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

extension DownloadItem {
    var progressBoxes: [ProgressBox] {
        ProgressBoxes.make(snapshot, count: laneCount, completed: status == .completed)
    }

    /// A media item's boxes per part, in plan order (video, then audio): each part split by its own connections.
    var mediaPartBoxes: [[ProgressBox]] {
        guard let media, !media.parts.isEmpty else { return [progressBoxes] }
        let perPart = max(1, maxConnections / media.parts.count)
        let done = status == .completed
        return media.parts.map { part in
            guard let detail = part.detail else { return ProgressBoxes.make(.placeholder(fileName: ""), count: 1, completed: done) }
            let partDone = done || part.state == .completed
            return ProgressBoxes.make(detail, count: detail.acceptsRanges ? min(perPart, 32) : 1, completed: partDone)
        }
    }

    var isMerging: Bool { media?.phase == .merging }

    /// The bar colour for the item's state: accent while running, orange paused, green done.
    var barColor: Color {
        switch status {
        case .downloading, .queued: Theme.accent
        case .paused: Theme.orange
        case .completed: Theme.green
        case .failed: Theme.error
        }
    }
}
