import AppKit
import OspreyEngine
import SwiftUI

/// The content of a capture's floating progress window: what is downloading, how far along it is,
/// and the few actions that matter. Shows the host only, never the URL, headers or cookies.
struct CaptureProgressView: View {
    struct Actions {
        var close: () -> Void
        var showAll: () -> Void
        /// The panel's accessibility title; the panels controller applies it a turn later, outside layout.
        var setTitle: (String) -> Void
        var pointerInside: () -> Bool
    }

    let item: DownloadItem
    let manager: DownloadManager
    let actions: Actions

    enum Phase: Equatable {
        case starting, queued, running, paused, completed
        case failed(String)
    }

    private var phase: Phase {
        switch item.status {
        case .completed: return .completed
        case .failed: return .failed(item.errorMessage ?? "The download stopped.")
        case .paused: return .paused
        case .queued: return .queued
        case .downloading:
            switch item.snapshot.state {
            case .downloading, .finishing: return .running
            default: return .starting   // idle, probing, or a retry that hasn't reported yet
            }
        }
    }

    private var isTracked: Bool { manager.items.contains { $0.id == item.id } }

    var body: some View {
        let snapshot = item.snapshot
        let phase = phase
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(state: Self.stateLabel(phase), color: Self.stateColor(phase), close: actions.close)
            fileRow(snapshot, phase: phase)
            switch phase {
            case .completed:
                EmptyView()
            case .failed(let message):
                ErrorBox(message: message)
            default:
                progress(snapshot, phase: phase)
            }
            buttons(phase)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: CaptureProgressPanels.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .glassPanel(cornerRadius: 22, fill: Theme.panel)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        // Only on phase changes, not on every percent: the panel is borderless, the title is for accessibility.
        // (The Appearance setting is applied by CaptureProgressPanels, never from inside this view's update.)
        .onChange(of: phase, initial: true) { _, phase in actions.setTitle(Self.windowTitle(phase)) }
        .onChange(of: isTracked) { _, tracked in if !tracked { actions.close() } }
        .task(id: phase == .completed) { await autoCloseWhenComplete() }
    }

    // MARK: Rows

    private func fileRow(_ snapshot: DownloadSnapshot, phase: Phase) -> some View {
        HStack(spacing: 12) {
            CategoryTile(category: item.category, size: 44, cornerRadius: 12, symbolSize: 19)
                .overlay(alignment: .bottomTrailing) { badge(phase) }
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.fileName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.fileName)
                Text(meta(snapshot, phase: phase))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func badge(_ phase: Phase) -> some View {
        switch phase {
        case .completed: PanelBadge(symbol: "checkmark", color: Theme.greenBadge)
        case .failed: PanelBadge(symbol: "exclamationmark", color: Theme.error)
        case .paused: PanelBadge(symbol: "pause.fill", color: Theme.orange)
        default: EmptyView()
        }
    }

    /// "host · size", or where a finished download was saved.
    private func meta(_ snapshot: DownloadSnapshot, phase: Phase) -> String {
        if phase == .completed {
            let size = snapshot.totalSize.map(Format.bytes) ?? Format.bytes(snapshot.downloaded)
            guard let folder = snapshot.destination?.deletingLastPathComponent() else { return size }
            return "\(size) · saved to \(Format.crumbs(folder))"
        }
        let size = snapshot.totalSize.map(Format.bytes) ?? (phase == .starting ? "checking file…" : "size unknown")
        return "\(item.host) · \(size)"
    }

    private func progress(_ snapshot: DownloadSnapshot, phase: Phase) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                if phase == .starting || (phase == .running && snapshot.totalSize == nil) {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                } else {
                    SegmentedProgressBar(boxes: item.progressBoxes, color: item.barColor)
                }
                Text(snapshot.totalSize == nil || phase == .starting ? "—" : "\(Int(item.progress * 100))%")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(height: 16)
            stats(snapshot, phase: phase)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func stats(_ snapshot: DownloadSnapshot, phase: Phase) -> some View {
        HStack(spacing: 14) {
            switch phase {
            case .starting:
                Text("Connecting").fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                Text("Checking the file…")
            case .queued:
                Text("Waiting for a free download slot")
            case .paused:
                Text("Paused").fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                Text(amount(snapshot))
            default:
                Text(Format.speed(snapshot.bytesPerSecond))
                    .fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("Speed \(Format.speed(snapshot.bytesPerSecond))")
                Text(snapshot.lanes.count == 1 ? "1 connection" : "\(snapshot.lanes.count) connections")
                if let remaining = item.remaining {
                    let eta = Format.eta(remaining: remaining, speed: snapshot.bytesPerSecond)
                    if eta != "—" { Text("\(eta) left") }
                }
            }
        }
        .monospacedDigit()
    }

    private func amount(_ snapshot: DownloadSnapshot) -> String {
        guard let total = snapshot.totalSize else { return Format.bytes(snapshot.downloaded) }
        return "\(Format.bytes(snapshot.downloaded)) of \(Format.bytes(total))"
    }

    // MARK: Buttons

    private func buttons(_ phase: Phase) -> some View {
        HStack(spacing: 8) {
            Button("Show all", action: actions.showAll)
                .buttonStyle(.capsule(.text))
                .help("Open Osprey with this download selected")
            Spacer(minLength: 0)
            switch phase {
            case .completed:
                Button("Show in Finder") {
                    if let url = item.snapshot.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .buttonStyle(.capsule(.secondary))
                Button("Open") {
                    if let url = item.snapshot.destination { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.capsule(.primary))
            case .failed:
                removeButton("Remove")
                Button("Retry") { manager.resume(item) }
                    .buttonStyle(.capsule(.primary))
            case .paused:
                removeButton("Cancel")
                Button("Resume") { manager.resume(item) }
                    .buttonStyle(.capsule(.primary))
            case .starting, .queued, .running:
                removeButton("Cancel")
                Button("Pause") { manager.pause(item) }
                    .buttonStyle(.capsule(.primary))
                    .disabled(item.isMerging)
            }
        }
    }

    /// Stops the download and deletes its partial data, the same as Remove in the main window.
    private func removeButton(_ title: String) -> some View {
        Button(title) {
            manager.remove(item)
            actions.close()
        }
        .buttonStyle(.capsule(.secondary))
        .help("Stop and delete the partial download")
    }

    // MARK: Behaviour

    static func windowTitle(_ phase: Phase) -> String {
        switch phase {
        case .starting: "Starting download"
        case .queued: "Queued"
        case .running: "Downloading"
        case .paused: "Paused"
        case .completed: "Download complete"
        case .failed: "Download failed"
        }
    }

    static func stateLabel(_ phase: Phase) -> String {
        switch phase {
        case .starting: "Starting"
        case .queued: "Queued"
        case .running: "Downloading"
        case .paused: "Paused"
        case .completed: "Complete"
        case .failed: "Failed"
        }
    }

    static func stateColor(_ phase: Phase) -> Color {
        switch phase {
        case .starting, .queued: Theme.textSecondary
        case .running: Theme.accent
        case .paused: Theme.orange
        case .completed: Theme.green
        case .failed: Theme.error
        }
    }

    /// Closes a completed download's window after 10 s, waiting while the pointer is over it.
    private func autoCloseWhenComplete() async {
        guard phase == .completed else { return }
        do {
            try await Task.sleep(for: .seconds(10))
            while actions.pointerInside() { try await Task.sleep(for: .milliseconds(500)) }
        } catch {
            return   // cancelled: the phase changed or the window went away
        }
        actions.close()
    }
}

/// "▣ Osprey · Downloading" and the close button.
private struct PanelHeader: View {
    let state: String
    let color: Color
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            Text("Osprey").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text("· \(state)").font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Theme.chip, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .help("Close")
        }
    }
}

/// The small state badge on the file tile: a check, an exclamation mark or a pause sign.
private struct PanelBadge: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(Color(light: 0xFFFFFF, dark: 0x2C2C32), lineWidth: 2).padding(-2))
            .offset(x: 4, y: 4)
            .accessibilityHidden(true)
    }
}
