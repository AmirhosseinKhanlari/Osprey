import SwiftUI

struct DownloadListView: View {
    @Environment(DownloadManager.self) private var manager
    let items: [DownloadItem]
    @Binding var selection: DownloadItem.ID?
    @State private var pendingRemoval: DownloadItem?
    @State private var width: CGFloat = 800
    @FocusState private var focused: Bool

    var body: some View {
        let columns = ListColumns(width: width)
        VStack(spacing: 0) {
            // The header's fixed-width columns must not set this view's minimum width. On the macOS 27 SDK,
            // a rigid minimum here makes the navigation split view and the inspector's split view keep
            // re-sizing each other until AppKit aborts ("needing another Update Constraints in Window
            // pass"). Drawing it as an overlay on a fixed-height spacer keeps its look without that.
            Color.clear
                .frame(height: 38)
                .overlay(alignment: .leading) { header(columns) }
                .clipped()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if items.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Add a URL or capture a download from your browser."))
                    .frame(maxHeight: .infinity)
            } else {
                rows(columns)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .surfaceCard()
        .confirmationDialog(
            "Remove “\(pendingRemoval?.snapshot.fileName ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval { manager.remove(item) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.status == .completed
                 ? "The downloaded file stays on disk."
                 : "The partially downloaded data will be deleted.")
        }
    }

    private func rows(_ columns: ListColumns) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        // Same overlay pattern as the header: the row's columns never size the list.
                        Color.clear
                            .frame(height: 62)
                            .overlay { DownloadRow(item: item, columns: columns, selected: selection == item.id) }
                            .contentShape(Rectangle())
                            .onTapGesture { select(item) }
                            // VoiceOver: one element per row that reads as a selectable button, with
                            // the same Select and Remove a mouse user has.
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(selection == item.id ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { select(item) }
                            .accessibilityAction(named: "Remove") { pendingRemoval = item }
                            .contextMenu { menu(for: item) }
                            .id(item.id)
                    }
                }
                .padding(6)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in requestRemovalOfSelection() }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private func select(_ item: DownloadItem) {
        selection = item.id
        focused = true
    }

    /// Delete asks first, through the same confirmation as the context menu's Remove.
    private func requestRemovalOfSelection() -> KeyPress.Result {
        guard let item = items.first(where: { $0.id == selection }) else { return .ignored }
        pendingRemoval = item
        return .handled
    }

    /// Arrow keys move the selection, as in a table.
    private func move(by offset: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + offset, 0), items.count - 1) } ?? (offset > 0 ? 0 : items.count - 1)
        selection = items[next].id
        return .handled
    }

    private func header(_ columns: ListColumns) -> some View {
        HStack(spacing: ListColumns.gap) {
            HStack(spacing: 8) {
                Text("Name")
                Spacer(minLength: 0)
                // Only while a finished download is listed. It never touches failed or unfinished ones, or any file.
                if items.contains(where: { $0.status == .completed }) {
                    Button("Clear completed") { manager.clearCompleted(in: items) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help("Remove finished downloads from the list. Their files stay on disk.")
                        // Not a keyboard stop: as the first focusable control it would take focus at launch, where Space
                        // would clear the list.
                        .focusable(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Progress").frame(width: columns.progress, alignment: .leading)
            if let speed = columns.speed { Text("Speed").frame(width: speed, alignment: .leading) }
            if let eta = columns.eta { Text("Time left").frame(width: eta, alignment: .leading) }
            Text("Status").frame(width: columns.status, alignment: .leading)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, 18)
    }

    @ViewBuilder private func menu(for item: DownloadItem) -> some View {
        if item.status == .downloading || item.status == .queued {
            Button("Pause") { manager.pause(item) }
                .disabled(item.isMerging)               // merging can't be paused
        } else if item.status != .completed {
            Button(item.resumeTitle) { manager.resume(item) }   // Resume, Retry (a restored failure) or Restart
        } else if item.fileMissing {
            Button("Retry") { manager.retry(item) }
        }
        // A finished file that is missing offers only Retry and Remove from list.
        if !item.fileMissing {
            if let destination = item.snapshot.destination {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
        }
        Divider()
        if item.status == .completed {
            Button("Remove from list") { manager.removeFromList(item) }   // the file stays on disk
        } else {
            Button("Remove", role: .destructive) { pendingRemoval = item }
        }
    }
}

/// The list's column widths for the card's width. Narrow cards drop Time left, then Speed
/// (both stay in the inspector), so the name keeps room.
struct ListColumns {
    static let gap: CGFloat = 18
    /// Card inset (6) plus row padding (12) on each side.
    static let inset: CGFloat = 36

    var progress: CGFloat = 210
    var speed: CGFloat? = 86
    var eta: CGFloat? = 74
    var status: CGFloat = 108

    init(width: CGFloat) {
        let inner = width - Self.inset
        if inner - (210 + 86 + 74 + 108 + Self.gap * 4) >= 200 { return }
        eta = nil
        progress = 150
        if inner - (150 + 86 + 108 + Self.gap * 3) >= 160 { return }
        speed = nil
        progress = 130
    }
}
