import OspreyEngine
import OspreyMedia
import SwiftUI

struct InspectorView: View {
    let item: DownloadItem?

    var body: some View {
        Group {
            if let item {
                InspectorDetails(item: item).id(item.id)
            } else {
                ContentUnavailableView("No selection", systemImage: "sidebar.right",
                                       description: Text("Select a download to see its connections."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 16, fill: Theme.inspector)
        .padding([.trailing, .bottom], 8)
        // Fill the whole column (also under the toolbar); otherwise the rest shows the system's grey panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop().ignoresSafeArea())
    }
}

private struct InspectorDetails: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem
    /// The media part whose connections are listed; nil lists every part's.
    @State private var selectedPart: Int?

    private var mediaTask: MediaDownload? { item.task as? MediaDownload }

    var body: some View {
        let snapshot = item.snapshot
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(snapshot)
                    progress(snapshot)
                    if let message = item.errorMessage { ErrorBox(message: message) }
                    if let message = item.warningMessage { ErrorBox(message: message, isWarning: true) }
                    if item.fileMissing { ErrorBox(message: "File missing", isWarning: true) }
                    stats(snapshot)
                    if item.kind == .media, let media = item.media, let task = mediaTask {
                        InspectorParts(media: media, plan: task.plan, completed: item.status == .completed, selection: $selectedPart)
                        InspectorLanes(snapshot: lanesSnapshot(media) ?? snapshot,
                                       title: selectedPart.flatMap { media.parts.indices.contains($0) ? media.parts[$0] : nil }
                                           .map { "\(DownloadItem.partName($0.role)) connections" } ?? "Connections")
                    } else {
                        InspectorLanes(snapshot: snapshot)
                    }
                    details(snapshot)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            actions(snapshot)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
    }

    private func header(_ snapshot: DownloadSnapshot) -> some View {
        HStack(spacing: 12) {
            CategoryTile(category: item.category, size: 50, cornerRadius: 13, symbolSize: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.fileName)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(item.host).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }

    private func progress(_ snapshot: DownloadSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Group {
                    if let total = snapshot.totalSize {
                        Text("\(Text(Format.bytes(snapshot.downloaded)).foregroundStyle(Theme.textPrimary).fontWeight(.semibold)) of \(Format.bytes(total))")
                    } else {
                        Text("\(Text(Format.bytes(snapshot.downloaded)).foregroundStyle(Theme.textPrimary).fontWeight(.semibold)) · size unknown")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                Spacer(minLength: 8)
                if item.isMerging {
                    Text(item.mergingText).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                } else {
                    Text(item.status == .completed ? "100%" : (snapshot.totalSize == nil ? "—" : "\(Int(item.progress * 100))%"))
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)
                        .monospacedDigit()
                }
            }
            if item.kind == .media {
                MediaProgressBar(parts: item.mediaPartBoxes, merging: item.isMerging, color: item.barColor, height: 10,
                                 summary: item.mediaPartsSummary(spoken: true), mergingText: item.mergingText)
            } else {
                SegmentedProgressBar(boxes: item.progressBoxes, color: item.barColor, height: 10)
            }
        }
    }

    /// The selected part's own snapshot, while it's running (a paused part has no open connections).
    private func lanesSnapshot(_ media: MediaSnapshot) -> DownloadSnapshot? {
        guard let index = selectedPart, media.parts.indices.contains(index), item.status == .downloading,
              media.phase == .downloading else { return nil }
        return media.parts[index].detail
    }

    private func stats(_ snapshot: DownloadSnapshot) -> some View {
        let running = item.status == .downloading
        let timeLeft: String = switch item.status {
        case .downloading: item.remaining.map { Format.eta(remaining: $0, speed: snapshot.bytesPerSecond, units: 2) } ?? "—"
        case .completed: "Done"
        default: "—"
        }
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                StatTile(title: "Speed", value: running ? Format.speed(snapshot.bytesPerSecond) : "—")
                StatTile(title: "Time left", value: timeLeft)
            }
            GridRow {
                StatTile(title: "Connections", value: "\(snapshot.lanes.count) of \(item.laneCount)")
                StatTile(title: "Average", value: item.averageSpeed.map(Format.speed) ?? "—")
            }
        }
    }

    private func details(_ snapshot: DownloadSnapshot) -> some View {
        let folder = snapshot.destination?.deletingLastPathComponent()
            ?? mediaTask?.folder
            ?? manager.rootFolder.appending(path: item.category.rawValue)
        return VStack(spacing: 8) {
            detail("Saved to") {
                Text(Format.path(folder)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let task = mediaTask {
                detail("Page") { Text(item.host).lineLimit(1).truncationMode(.middle) }
                if let uploader = task.info.uploader?.trimmingCharacters(in: .whitespacesAndNewlines), !uploader.isEmpty {
                    detail("Uploader") { Text(uploader).lineLimit(1).truncationMode(.tail).textSelection(.enabled) }
                }
                if let playlist = item.playlistTitle, !playlist.isEmpty {
                    detail("Playlist") { Text(playlist).lineLimit(1).truncationMode(.tail) }
                }
            }
            detail("From") { Text(item.origin.label) }
            detail("Resume") {
                if snapshot.totalSize == nil && snapshot.state == .idle {
                    Text("Not checked yet").foregroundStyle(Theme.textSecondary)
                } else if snapshot.acceptsRanges {
                    Text("Supported").fontWeight(.semibold).foregroundStyle(Theme.green)
                } else {
                    Text("Not supported").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func detail(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            value()
        }
        .accessibilityElement(children: .combine)
    }

    private func actions(_ snapshot: DownloadSnapshot) -> some View {
        HStack(spacing: 8) {
            switch item.status {
            case .downloading, .queued:
                Button("Pause") { manager.pause(item) }
                    .disabled(item.isMerging)           // merging can't be paused
            case .paused, .failed:
                Button(item.resumeTitle) { manager.resume(item) }
            case .completed:
                if item.fileMissing {
                    Button("Retry") { manager.retry(item) }
                } else {
                    Button("Open") { if let url = snapshot.destination { NSWorkspace.shared.open(url) } }
                }
            }
            if item.fileMissing {
                Button("Remove from list") { manager.removeFromList(item) }
            } else {
                Button("Show in Finder") {
                    if let url = snapshot.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(snapshot.destination == nil)
            }
        }
        .buttonStyle(.capsule(.secondary, height: 34, fontSize: 13, fillWidth: true))
    }
}

/// The inspector's per-connection list: lane number, its range's progress and its speed.
private struct InspectorLanes: View {
    let snapshot: DownloadSnapshot
    var title = "Connections"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            if snapshot.lanes.isEmpty {
                Text("No open connections.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: 22)
            } else {
                ForEach(snapshot.lanes) { lane in
                    row(lane, segment: snapshot.segments.first { $0.id == lane.segmentID })
                }
            }
        }
    }

    private func row(_ lane: LaneSnapshot, segment: Segment?) -> some View {
        let stalled = lane.phase == .stalled
        let fraction = segment.map { Double(min($0.received, $0.length)) / Double(max($0.length, 1)) } ?? 0
        let speed: String = switch lane.phase {
        case .connecting: "connecting"
        case .receiving: Format.speed(lane.bytesPerSecond)
        case .stalled: "stalled"
        }
        return HStack(spacing: 10) {
            Text("\(lane.id + 1)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20, alignment: .leading)
            Capsule()
                .fill(Theme.track)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(stalled ? Theme.orange : Theme.accent).frame(width: proxy.size.width * fraction)
                    }
                }
                .clipShape(Capsule())
                .frame(height: 4)
            Text(speed)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(stalled ? Theme.orange : (lane.phase == .connecting ? Theme.textTertiary : Theme.textSecondary))
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection \(lane.id + 1), \(Int(fraction * 100)) percent, \(speed)")
    }
}

/// A media item's parts: video, audio and subtitles, each with its size and state. Choosing a downloading part lists
/// only its connections below; choosing it again lists them all.
private struct InspectorParts: View {
    let media: MediaSnapshot
    let plan: MediaPlan
    let completed: Bool
    @Binding var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Parts")
            VStack(spacing: 0) {
                ForEach(media.parts.indices, id: \.self) { index in
                    let part = media.parts[index]
                    let format = plan.parts.indices.contains(index) ? plan.parts[index].format : nil
                    Button {
                        selection = selection == index ? nil : index
                    } label: {
                        row(symbol: part.role == .audio ? "waveform" : "film",
                            name: DownloadItem.partName(part.role),
                            detail: format.map(Self.formatLabel) ?? "",
                            size: size(part),
                            state: state(part),
                            selected: selection == index)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(selection == index ? "Shows every part's connections" : "Shows this part's connections")
                    .accessibilityAddTraits(selection == index ? .isSelected : [])
                }
                if plan.parts.contains(where: { $0.role != .audio }) {
                    row(symbol: "captions.bubble", name: "Subtitles",
                        detail: plan.subtitleLanguage.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 } ?? "",
                        size: plan.subtitle == nil ? "" : "—", state: subtitleState, selected: false)
                }
            }
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(symbol: String, name: String, detail: String, size: String, state: (text: String, color: Color),
                     selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(state.text).font(.system(size: 12, weight: .medium)).foregroundStyle(state.color).monospacedDigit().lineLimit(1)
                if !size.isEmpty {
                    Text(size).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).monospacedDigit().lineLimit(1)
                }
            }
            .layoutPriority(1)   // the size and state stay whole; the format line truncates first
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "1080p · H.264" for video, "AAC · M4A" for audio.
    static func formatLabel(_ format: MediaFormat) -> String {
        var bits: [String] = []
        if format.hasVideo, let height = format.height { bits.append("\(height)p") }
        if format.hasVideo, !format.codecLabel.isEmpty { bits.append(format.codecLabel) }
        if !format.hasVideo, format.isAAC { bits.append("AAC") }
        else if !format.hasVideo, let codec = format.acodec, codec != "none" { bits.append(codec.split(separator: ".").first.map { $0.uppercased() } ?? codec) }
        if !format.hasVideo || bits.isEmpty { bits.append(format.ext.uppercased()) }
        return bits.joined(separator: " · ")
    }

    private func size(_ part: MediaPartStatus) -> String {
        guard let total = part.total else { return part.downloaded > 0 ? Format.bytes(part.downloaded) : "—" }
        if completed || part.state == .completed { return Format.bytes(total) }
        return "\(Format.bytes(part.downloaded)) of \(Format.bytes(total))"
    }

    private func state(_ part: MediaPartStatus) -> (text: String, color: Color) {
        if completed { return ("Done", Theme.green) }
        switch part.state {
        case .idle: return ("Waiting", Theme.textTertiary)
        case .probing: return ("Connecting", Theme.textSecondary)
        case .downloading:
            guard let total = part.total, total > 0 else { return ("Downloading", Theme.accent) }
            return ("\(Int(Double(min(part.downloaded, total)) / Double(total) * 100))%", Theme.accent)
        case .finishing: return ("Finishing", Theme.accent)
        case .paused: return ("Paused", Theme.orange)
        case .completed: return ("Done", Theme.green)
        case .failed: return ("Failed", Theme.error)
        }
    }

    private var subtitleState: (text: String, color: Color) {
        guard plan.subtitle != nil else { return ("None", Theme.textTertiary) }
        if media.warning != nil { return ("Not embedded", Theme.orange) }
        if completed { return ("Embedded", Theme.green) }
        if media.phase == .merging { return ("Embedding…", Theme.accent) }
        if case .failed = media.phase { return ("Not embedded", Theme.textTertiary) }
        return ("At merge", Theme.textSecondary)
    }
}

/// A failure message on a soft red box (or, with `isWarning`, a warning on a soft orange one), with a warning symbol.
struct ErrorBox: View {
    let message: String
    /// Orange, for a finished download that left something out, instead of red for a failure.
    var isWarning = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isWarning ? Theme.orange : Theme.error)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isWarning ? Theme.orange.opacity(0.12) : Theme.errorSoft,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
