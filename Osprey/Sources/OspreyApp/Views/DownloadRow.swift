import OspreyEngine
import OspreyMedia
import SwiftUI

struct DownloadRow: View {
    let item: DownloadItem
    let columns: ListColumns
    let selected: Bool

    var body: some View {
        let snapshot = item.snapshot
        HStack(spacing: ListColumns.gap) {
            HStack(spacing: 12) {
                CategoryTile(category: item.category)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.fileName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                if item.kind == .media {
                    MediaProgressBar(parts: item.mediaPartBoxes, merging: item.isMerging, color: item.barColor,
                                     summary: item.mediaPartsSummary(spoken: true), mergingText: item.mergingText)
                } else {
                    SegmentedProgressBar(boxes: item.progressBoxes, color: item.barColor)
                }
                if item.fileMissing {
                    // A finished file that was deleted or moved since: only Retry and Remove from list remain.
                    Label("File missing", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // A narrow column drops the connection count first, then the parts, rather than truncating.
                    ViewThatFits(in: .horizontal) {
                        ForEach(progressTexts, id: \.self) { text in
                            Text(text)
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: columns.progress)
            if let width = columns.speed {
                Text(item.status == .downloading ? Format.speed(snapshot.bytesPerSecond) : "—")
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
            if let width = columns.eta {
                Text(timeLeft)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
            StatusPill(status: item.status).frame(width: columns.status, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "host · size", and for a playlist's video "· <playlist title>".
    private var meta: String {
        var parts = [item.host]
        if let total = item.snapshot.totalSize { parts.append(Format.bytes(total)) }
        if let playlist = item.playlistTitle, !playlist.isEmpty { parts.append(playlist) }
        return parts.joined(separator: " · ")
    }

    /// The progress text, then shorter forms of it for a narrow column (media items only; the last always fits):
    /// "Video 64% · Audio 20% · 8 connections" (or "· paused", "· failed"), "Video 64% · Audio 20%",
    /// "38% · 8 connections" (or "38% · paused"), "38%".
    private var progressTexts: [String] {
        let full = progressText
        guard item.kind == .media, !item.isMerging, item.mediaProgressText != nil else { return [full] }
        let parts = item.mediaPartsSummary(spoken: false)
        let lanes = item.snapshot.lanes.count
        let suffix: String? = switch item.status {
        case .downloading: lanes == 0 ? nil : (lanes == 1 ? "1 connection" : "\(lanes) connections")
        case .paused: "paused"
        case .failed: "failed"
        case .queued, .completed: nil
        }
        let known = item.snapshot.totalSize != nil
        let short = known ? [percent, suffix].compactMap { $0 }.joined(separator: " · ") : parts
        var seen = Set<String>()
        return [full, parts, short, known ? percent : parts].filter { seen.insert($0).inserted }   // ForEach needs unique ids
    }

    private var percent: String { "\(Int(item.progress * 100))%" }

    private var progressText: String {
        let snapshot = item.snapshot
        if item.kind == .media, let text = item.mediaProgressText { return text }
        switch item.status {
        case .downloading:
            let lanes = snapshot.lanes.count
            guard lanes > 0 else { return "Starting…" }
            let connections = lanes == 1 ? "1 connection" : "\(lanes) connections"
            return snapshot.totalSize == nil ? "\(Format.bytes(snapshot.downloaded)) · \(connections)" : "\(percent) · \(connections)"
        case .queued:
            return "Waiting in queue"
        case .paused:
            return snapshot.totalSize == nil ? "Paused" : "\(percent) · paused"
        case .completed:
            return item.completedAt.map { "Finished \(Format.ago($0))" } ?? "Finished"
        case .failed:
            return snapshot.totalSize == nil ? "Failed" : "\(percent) · failed"
        }
    }

    private var timeLeft: String {
        switch item.status {
        case .downloading: item.remaining.map { Format.eta(remaining: $0, speed: item.snapshot.bytesPerSecond) } ?? "—"
        default: "—"
        }
    }
}

extension DownloadItem {
    /// A media item's row text: "Video 64% · Audio 100% · 8 connections"; "Merging…" while the parts are joined
    /// ("Converting…" for an MP3).
    /// nil when the plain file wording fits (queued, finished, before the parts report).
    var mediaProgressText: String? {
        guard kind == .media, let media else { return nil }
        if media.phase == .merging { return mergingText }
        if status == .completed { return warningMessage }
        guard !media.parts.isEmpty, media.parts.contains(where: { $0.detail != nil }) else { return nil }
        let parts = mediaPartsSummary(spoken: false)
        switch status {
        case .downloading:
            let lanes = snapshot.lanes.count
            // No open connection: before the first one ("Starting…"), or a part just finished and the next step is due.
            guard lanes > 0 else { return media.parts.contains { $0.downloaded > 0 } ? parts : "Starting…" }
            return "\(parts) · \(lanes == 1 ? "1 connection" : "\(lanes) connections")"
        case .paused: return "\(parts) · paused"
        case .failed: return "\(parts) · failed"
        case .queued, .completed: return nil
        }
    }

    /// "Video 64% · Audio 100%"; spoken: "Video 64 percent, audio 100 percent". A part of unknown size shows its bytes.
    func mediaPartsSummary(spoken: Bool) -> String {
        guard let media, !media.parts.isEmpty else { return "" }
        let done = status == .completed
        let texts = media.parts.enumerated().map { index, part in
            let name = Self.partName(part.role)
            let label = spoken && index > 0 ? name.lowercased() : name
            let amount: String
            if done || part.state == .completed {
                amount = spoken ? "100 percent" : "100%"
            } else if let total = part.total, total > 0 {
                let percent = Int(Double(min(part.downloaded, total)) / Double(total) * 100)
                amount = spoken ? "\(percent) percent" : "\(percent)%"
            } else {
                amount = Format.bytes(part.downloaded)
            }
            return "\(label) \(amount)"
        }
        return texts.joined(separator: spoken ? ", " : " · ")
    }

    /// The finishing step's name: an MP3 is converted, anything else merged (parts, or a video with its subtitles).
    var mergingText: String {
        (task as? MediaDownload)?.plan.convertToMP3 == true ? "Converting…" : "Merging…"
    }

    static func partName(_ role: MediaPart.Role) -> String {
        switch role {
        case .video, .combined: "Video"
        case .audio: "Audio"
        }
    }
}
