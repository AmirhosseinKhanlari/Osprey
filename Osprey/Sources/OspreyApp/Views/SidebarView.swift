import OspreyLibrary
import SwiftUI

/// The library, categories and queues on a floating glass panel, with the speed limit at the bottom.
struct SidebarView: View {
    @Environment(DownloadManager.self) private var manager
    @Binding var filter: SidebarFilter?
    @Binding var queueEditor: QueueEditorRequest?
    @State private var pendingDeletion: Queue?

    private let library: [SidebarFilter] = [.all, .downloading, .queued, .paused, .completed]
    private let categories = Category.allCases.filter { $0 != .other }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Library").padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                    ForEach(library, id: \.self) { item in
                        row(item) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(filter == item ? Theme.accent : Theme.textSecondary)
                                .frame(width: 22)
                        }
                    }
                    SectionLabel("Categories").padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                    ForEach(categories) { category in
                        row(.category(category)) {
                            CategoryTile(category: category, size: 22, cornerRadius: 6, symbolSize: 11)
                        }
                    }
                    queuesHeader.padding(.leading, 10).padding(.trailing, 4).padding(.top, 12).padding(.bottom, 2)
                    ForEach(manager.queues) { queue in queueRow(queue) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, Self.fade)
            }
            .scrollIndicators(.never)
            // Without scroll bars, a soft bottom edge shows there is more below (the queues, in a short window).
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
            // Like a sidebar list: one focus stop, arrow keys move the selection.
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            SpeedLimitCard()
                .padding(10)
        }
        // Room for the window controls and the sidebar toggle, which sit on the panel.
        .padding(.top, 44)
        .glassPanel(cornerRadius: 16, fill: Theme.glass)
        .padding([.leading, .top, .bottom], 8)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowBackdrop().ignoresSafeArea())
        .confirmationDialog("Delete “\(pendingDeletion?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { queue in
            Button("Delete", role: .destructive) {
                if filter == .queue(queue.id) { filter = .all }
                manager.deleteQueue(queue.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("Its downloads move to Main and stay paused.")
        }
    }

    /// The height of the scroll area's faded bottom edge, and the room left under the last row so it isn't faded.
    private static let fade: CGFloat = 14

    private var allFilters: [SidebarFilter] {
        library + categories.map { .category($0) } + manager.queues.map { .queue($0.id) }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let filters = allFilters
        let index = filters.firstIndex { $0 == filter } ?? 0
        filter = filters[min(max(index + offset, 0), filters.count - 1)]
        return .handled
    }

    /// "Queues" with a + that opens the editor for a new queue.
    private var queuesHeader: some View {
        HStack(spacing: 4) {
            SectionLabel("Queues")
            Spacer(minLength: 4)
            Button {
                queueEditor = .newQueue
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Add a queue")
            .accessibilityLabel("Add a queue")
        }
    }

    private func row(_ item: SidebarFilter, @ViewBuilder icon: () -> some View) -> some View {
        let selected = filter == item
        return Button { filter = item } label: {
            HStack(spacing: 10) {
                icon()
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(manager.count(for: item))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Name, status line ("Running · 2 of 3", "Starts 2:00 AM", …) and item count, with the queue's actions. The row
    /// keeps one height whatever the status says, so the list never shifts as queues start and stop.
    private func queueRow(_ queue: Queue) -> some View {
        let item = SidebarFilter.queue(queue.id)
        let selected = filter == item
        let status = manager.statusLine(for: queue)
        let mine = manager.items.filter { $0.queueID == queue.id }
        let running = mine.contains { $0.status == .downloading }
        let unfinished = mine.filter { $0.status != .completed }.count
        return Button { filter = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(queue.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                    Text(status)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(running ? Theme.green : Theme.textTertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                // Unfinished downloads only: finished ones stay listed under the queue but aren't its work.
                Text("\(unfinished)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("\(queue.name), \(status)")
        .accessibilityValue(unfinished == 1 ? "1 download" : "\(unfinished) downloads")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(QueueRowActions(queue: queue, edit: { queueEditor = QueueEditorRequest(queue: queue, isNew: false) },
                                  delete: { pendingDeletion = queue }))
        .contextMenu { menu(for: queue) }
    }

    /// Start now or Stop, Edit…, Move Up / Move Down and Delete…. Main only has Edit…: it runs by itself, stays first
    /// and can't be deleted.
    @ViewBuilder private func menu(for queue: Queue) -> some View {
        if !queue.isMain {
            if queue.isActive {
                Button("Stop") { manager.stop(queue: queue.id) }
            } else {
                Button("Start now") { manager.start(queue: queue.id) }
            }
        }
        Button("Edit…") { queueEditor = QueueEditorRequest(queue: queue, isNew: false) }
        if !queue.isMain {
            let index = manager.queues.firstIndex { $0.id == queue.id } ?? 0
            Divider()
            Button("Move Up") { manager.moveQueue(queue.id, by: -1) }
                .disabled(index <= 1)
            Button("Move Down") { manager.moveQueue(queue.id, by: 1) }
                .disabled(index >= manager.queues.count - 1)
            Divider()
            Button("Delete…", role: .destructive) { pendingDeletion = queue }
        }
    }
}

/// The context menu's actions as named accessibility actions, so a queue can be run and managed from the keyboard
/// (VoiceOver's actions menu): Start now or Stop, Edit, and Delete. Main has only Edit.
private struct QueueRowActions: ViewModifier {
    @Environment(DownloadManager.self) private var manager
    let queue: Queue
    let edit: () -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        if queue.isMain {
            content.accessibilityAction(named: "Edit", edit)
        } else {
            content
                .accessibilityAction(named: queue.isActive ? "Stop" : "Start now") {
                    if queue.isActive { manager.stop(queue: queue.id) } else { manager.start(queue: queue.id) }
                }
                .accessibilityAction(named: "Edit", edit)
                .accessibilityAction(named: "Delete", delete)
        }
    }
}
