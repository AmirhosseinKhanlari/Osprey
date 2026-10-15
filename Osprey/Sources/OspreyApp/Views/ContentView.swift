import OspreyMedia
import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(MediaCoordinator.self) private var media
    @State private var filter: SidebarFilter? = .all
    @State private var selection: DownloadItem.ID?
    @State private var search = ""
    @State private var showInspector = true
    @State private var showAdd = false
    @State private var showPicker = false
    /// The request the picker sheet is showing, so its onDismiss closes only that one.
    @State private var presentedRequestID: UUID?
    /// The picker sheet is animating out; a request arriving now is presented by its onDismiss.
    @State private var pickerClosing = false
    /// The picker was asked for while another sheet was up; it shows once that sheet has gone.
    @State private var pickerAfterSheet = false
    @AppStorage("didShowSafariSetup") private var didShowSafariSetup = false
    @State private var showSafariSetup = false
    /// First-run Safari setup came due while the picker was up; it shows after the picker.
    @State private var safariAfterPicker = false

    /// The shell holds the sheets and reads no download state; the window's content (which re-renders on every
    /// progress tick) is a separate view. A re-render of the view a sheet is attached to updates the sheet too, and
    /// that closed the picker's open menus (Quality, Audio, Subtitles) about once a second.
    var body: some View {
        MainWindowContent(filter: $filter, selection: $selection, search: $search, showInspector: $showInspector,
                          showAdd: $showAdd)
        .tint(Theme.accent)
        .sheet(isPresented: $showAdd, onDismiss: showQueuedPicker) { AddDownloadSheet() }
        .sheet(isPresented: $showSafariSetup, onDismiss: {
            didShowSafariSetup = true          // only once seen: a sheet lost to a launch-time race shows next launch
            showQueuedPicker()
        }) { SafariSetupSheet() }
        .sheet(isPresented: $showPicker, onDismiss: {
            let dismissed = presentedRequestID
            presentedRequestID = nil
            pickerClosing = false
            media.close(ifCurrent: dismissed)
            if media.isPresented {
                // A newer request arrived while this sheet animated out: present it on the next turn.
                DispatchQueue.main.async { if media.isPresented { showPicker = true } }
            } else if safariAfterPicker {
                safariAfterPicker = false
                showSafariSetup = true
            }
        }) {
            MediaPickerSheet()
                .environment(media)
                .frame(width: MediaPickerSheet.size.width, height: MediaPickerSheet.size.height)
                // Follows the request while the sheet stays up (a second click replaces the first).
                .onChange(of: media.request?.id, initial: true) { _, id in
                    if !pickerClosing, let id { presentedRequestID = id }
                }
        }
        // The coordinator asks for the picker (Add URL's "Download video instead", or a browser); initial:
        // covers a main window that was just opened for it. One sheet at a time: Add URL closes first (the picker
        // replaces it); the Safari setup sheet is left for the user to finish, and the picker follows it.
        .onChange(of: media.isPresented, initial: true) { _, presented in
            if presented {
                if showAdd {
                    pickerAfterSheet = true
                    showAdd = false
                } else if showSafariSetup {
                    pickerAfterSheet = true
                } else if !pickerClosing {
                    showPicker = true
                }                                      // else: the closing sheet's onDismiss presents it
            } else {
                pickerAfterSheet = false
                if showPicker {
                    pickerClosing = true
                    showPicker = false
                }
            }
        }
        .task {
            guard !didShowSafariSetup, CaptureNotifier.isAvailable else { return }
            if showPicker || media.isPresented { safariAfterPicker = true } else { showSafariSetup = true }
        }
        // A progress window's "Show all" asks for its download; initial: covers a window it just reopened.
        .onChange(of: manager.focusRequest, initial: true) { _, id in
            guard let id else { return }
            if manager.items.contains(where: { $0.id == id }) {
                filter = .all
                search = ""
                selection = id
                showInspector = true
            }
            manager.focusRequest = nil
        }
    }

    /// Shows the picker that waited for another sheet to close.
    private func showQueuedPicker() {
        guard pickerAfterSheet else { return }
        pickerAfterSheet = false
        showPicker = media.isPresented
    }
}

/// The main window's content: sidebar, throughput card, list and inspector. It reads the download manager, so it
/// re-renders while downloads run; the sheets live on `ContentView`, which doesn't.
private struct MainWindowContent: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(MediaCoordinator.self) private var media
    @Binding var filter: SidebarFilter?
    @Binding var selection: DownloadItem.ID?
    @Binding var search: String
    @Binding var showInspector: Bool
    @Binding var showAdd: Bool
    /// Bumped by Edit › Find (⌘F) through `focusedSceneValue`; the search field focuses itself when it changes. (A focus
    /// binding owned here doesn't reach the field, which the toolbar hosts on its own.)
    @State private var searchFocusRequest = 0

    var body: some View {
        let current = filter ?? .all
        let visible = manager.items(for: current, search: search)
        NavigationSplitView {
            SidebarView(filter: $filter)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 14) {
                ThroughputCard(history: manager.throughputHistory, current: manager.totalSpeed,
                               connections: manager.activeConnections, remaining: manager.remainingBytes,
                               active: manager.activeCount)
                DownloadListView(items: visible, selection: $selection)
                    .overlay(alignment: .bottom) {
                        if let text = PlaylistBatchProgress.bannerText(media.batchList) {
                            PlaylistBatchBanner(text: text) { media.cancelPlaylistBatches() }
                                .padding(.bottom, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: media.batches.isEmpty)
            }
            .padding(.top, 8)
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .padding(.bottom, 16)
            .background(WindowBackdrop().ignoresSafeArea())
            // The backdrop shows through the toolbar, as in the design; its items carry their own glass.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(current.title)
            .navigationSubtitle(subtitle(visible.count))
            .modifier(LegacySearchField(search: $search, focusRequest: searchFocusRequest))
            .focusedSceneValue(\.focusSearch, FocusSearchAction { searchFocusRequest += 1 })
            .toolbar {
                // Acts on the selected download only; Pause All / Resume All live in the Downloads menu.
                if let item = selectedItem, item.status != .completed {
                    ToolbarItem { selectionControl(for: item) }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.fixed)
                    }
                }
                // [search capsule] 8 pt [+ circle]: two glass shapes of their own. The toolbar's principal slot
                // hosts its items as one glass group (an Add URL item joined the search capsule, on its left),
                // so both are laid out here and the shared glass is turned off.
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .principal) {
                        // 10 pt apart: each glass rim draws about 1 pt outside its shape, so the visible gap is 8 pt.
                        HStack(spacing: 10) {
                            ToolbarSearchField(text: $search, focusRequest: searchFocusRequest)
                            addURLButton
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { addURLButton }
                }
                // While the inspector is open its own toolbar section carries the toggle (see below).
                if !showInspector {
                    ToolbarItem { inspectorToggle }
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(item: manager.items.first { $0.id == selection })
                    .inspectorColumnWidth(min: 300, ideal: 344, max: 440)
                    .toolbar {
                        // macOS gives the inspector its own toolbar section; keep the toggle at its far right.
                        // Only while shown: the hidden inspector's toolbar items would otherwise linger
                        // next to the main toolbar's toggle, giving two buttons.
                        if showInspector {
                            if #available(macOS 26, *) {
                                ToolbarSpacer(.flexible)
                            }
                            ToolbarItem(placement: .primaryAction) { inspectorToggle }
                        }
                    }
            }
        }
    }

    /// "3 active · 42.6 MB/s" while downloading, else the item count.
    private func subtitle(_ count: Int) -> String {
        let active = manager.activeCount
        guard active > 0 else { return count == 1 ? "1 item" : "\(count) items" }
        return "\(active) active · \(Format.speed(manager.totalSpeed))"
    }

    private var selectedItem: DownloadItem? {
        guard let selection else { return nil }
        return manager.items.first { $0.id == selection }
    }

    /// Pause for a running or queued download, Resume for a paused or failed one.
    @ViewBuilder
    private func selectionControl(for item: DownloadItem) -> some View {
        switch item.status {
        case .downloading, .queued:
            Button { manager.pause(item) } label: { Label("Pause", systemImage: "pause.fill") }
                .help(item.isMerging ? "Merging can’t be paused" : "Pause \(item.snapshot.fileName)")
                .disabled(item.isMerging)
        case .paused, .failed:
            Button { manager.resume(item) } label: {
                Label(item.resumeTitle, systemImage: item.resumeTitle == "Resume" ? "play.fill" : "arrow.clockwise")
            }
            .help("\(item.resumeTitle) \(item.snapshot.fileName)")
        case .completed:
            EmptyView()
        }
    }

    /// Add URL: a circular glass button the height of the toolbar's other icon buttons, its plus in the accent colour.
    @ViewBuilder
    private var addURLButton: some View {
        let button = Button { showAdd = true } label: {
            Label("Add URL", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: ToolbarMetrics.height, height: ToolbarMetrics.height)
                .contentShape(Circle())
        }
        .keyboardShortcut("n")
        .help("Add URL")
        if #available(macOS 26, *) {
            button.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Add URL")
        } else {
            button.accessibilityLabel("Add URL")
        }
    }

    private var inspectorToggle: some View {
        Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            .help(showInspector ? "Hide inspector" : "Show inspector")
    }
}

private enum ToolbarMetrics {
    /// The height of the toolbar's glass icon buttons (the inspector and sidebar toggles), so the search capsule and
    /// the Add URL circle line up with them.
    static let height: CGFloat = 36
}

/// Before macOS 26 the system search field stays in the toolbar's centre; from macOS 26 `ToolbarSearchField` replaces it.
private struct LegacySearchField: ViewModifier {
    @Binding var search: String
    let focusRequest: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content.searchable(text: $search, placement: .toolbarPrincipal, prompt: "Search files, sites…")
                .searchFocused($focused)
                .onChange(of: focusRequest) { focused = true }
        }
    }
}

/// Edit › Find (⌘F): focuses the main window's search field. Disabled while no main window is focused.
struct FindCommand: Commands {
    @FocusedValue(\.focusSearch) private var focusSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { focusSearch?.focus() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
    }
}

struct FocusSearchAction {
    let focus: () -> Void
}

extension FocusedValues {
    @Entry var focusSearch: FocusSearchAction?
}

/// The toolbar's search capsule (macOS 26 and later): it filters as you type, Edit › Find (⌘F) focuses it, Esc or the
/// clear button empties it. It takes the toolbar's free width up to a limit, and keeps a usable minimum. Clicks on the
/// text go to the text field itself; clicks on the rest of the capsule (the icon, the padding) focus it.
@available(macOS 26, *)
private struct ToolbarSearchField: View {
    @Binding var text: String
    let focusRequest: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .allowsHitTesting(false)               // a click on the icon reaches the capsule, which focuses the field
            TextField("Search files, sites…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
                .accessibilityLabel("Search downloads")
                .accessibilityAddTraits(.isSearchField)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ToolbarMetrics.height)
        .frame(minWidth: 220, idealWidth: 700, maxWidth: 760)
        // Behind the content, so only clicks that miss the text field and the clear button land here.
        .background {
            Capsule().fill(.clear).contentShape(Capsule()).onTapGesture { focused = true }
        }
        .glassEffect(.regular, in: Capsule())
        .onChange(of: focusRequest) { focused = true }
    }
}

/// "Adding 3 of 10 from “Playlist”…" (or several playlists' total) with Stop, while entries are looked up after
/// the picker closed.
private struct PlaylistBatchBanner: View {
    let text: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Stop", action: stop)
                .buttonStyle(.capsule(.secondary, height: 26, fontSize: 12))
                .help("Stop adding the playlist’s items. Ones already added stay.")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 20, fill: Theme.panel)
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
