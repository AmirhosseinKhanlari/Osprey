import AppKit
import SwiftUI

/// Owns the small floating progress windows shown when a browser hands a download to Osprey
/// (a classic download dialog). One panel per download, stacked down from the top-right corner of the
/// screen in use, at most `maxVisible` at a time; later ones wait for a free slot. Panels never
/// activate the app, so the browser keeps focus.
@MainActor
final class CaptureProgressPanels: NSObject, NSWindowDelegate {
    /// The card's width; its height follows the content (a failure message makes it taller).
    static let width: CGFloat = 384
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 10
    /// How many cards show at once. More wait (hidden, oldest first) until one closes; the stack never
    /// leaves the screen.
    static let maxVisible = 5

    private let manager: DownloadManager
    /// Opens (or brings forward) the main window. The SwiftUI scene installs it, since only a view
    /// can read `openWindow`; see `MainWindowOpenerRegistration`.
    var openMainWindow: (() -> Void)?
    private var panels: [DownloadItem.ID: ProgressPanel] = [:]
    /// Stacking order, oldest first (top of the stack).
    private var order: [DownloadItem.ID] = []
    /// The screen the current stack lives on; picked again when the stack empties.
    private weak var screen: NSScreen?
    private var relayoutScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    init(manager: DownloadManager) {
        self.manager = manager
        super.init()
        // The Appearance setting (Settings → General) is applied here, outside any SwiftUI update or AppKit
        // layout pass: setting a window's appearance from inside one asks AppKit for another constraint pass.
        appearanceObservation = UserDefaults.standard.observe(\.appearance, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    /// Shows the progress window for `item`, or brings its existing one forward.
    func show(_ item: DownloadItem) {
        if let panel = panels[item.id] {
            if panel.isVisible { panel.orderFrontRegardless() }   // a waiting one shows when a slot frees up
            return
        }
        if order.isEmpty || screen == nil { screen = Self.activeScreen() }
        let id = item.id
        let panel = ProgressPanel(size: CGSize(width: Self.width, height: 160))
        panel.delegate = self
        panel.appearance = Self.currentAppearance()   // before the content exists, so its first layout uses it
        panel.title = CaptureProgressView.windowTitle(.starting)
        let actions = CaptureProgressView.Actions(
            close: { [weak self] in self?.close(id) },
            showAll: { [weak self] in self?.showAll(id) },
            // A turn later, so a phase change seen during layout never touches the window inside it.
            setTitle: { [weak panel] title in DispatchQueue.main.async { panel?.title = title } },
            pointerInside: { [weak panel] in panel.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false })
        let hosting = NSHostingView(rootView: CaptureProgressView(item: item, manager: manager, actions: actions))
        hosting.sizingOptions = [.minSize, .maxSize]   // the card's fixed width and its content's height
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        panel.layoutIfNeeded()   // size the panel now; layout() stacks by the real frame
        panels[id] = panel
        order.append(id)
        layout(animated: false)   // orders the panel front, or leaves it waiting when the stack is full
    }

    func close(_ id: DownloadItem.ID) {
        panels[id]?.close()   // windowWillClose does the bookkeeping
    }

    private func showAll(_ id: DownloadItem.ID) {
        manager.focusRequest = id
        NSApp.activate()
        if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: NSWindowDelegate

    /// The card grew or shrank (its state changed): keep the stack's spacing and top edges.
    /// The resize arrives inside AppKit's constraint pass for that window; moving the window there
    /// would ask for another pass and AppKit aborts, so the relayout waits for the next turn.
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? ProgressPanel, panels.values.contains(where: { $0 === panel }),
              !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            relayoutScheduled = false
            panels.values.forEach { $0.invalidateShadow() }
            layout(animated: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? ProgressPanel,
              let id = panels.first(where: { $0.value === panel })?.key else { return }
        panels[id] = nil
        order.removeAll { $0 == id }
        panel.delegate = nil
        layout(animated: true)
    }

    // MARK: Placement

    /// One column in the top-right corner of the stack's screen, going down, oldest first. At most
    /// `maxVisible` cards show, and only while they fit above the bottom of the screen; the rest wait,
    /// hidden and in order, and appear as cards above them close. Nothing is ever placed off-screen.
    private func layout(animated: Bool) {
        guard let visible = (screen ?? Self.activeScreen())?.visibleFrame else { return }
        let x = visible.maxX - Self.margin - Self.width
        var top = visible.maxY - Self.margin
        var shown = 0
        var full = false
        for id in order {
            guard let panel = panels[id] else { continue }
            let size = panel.frame.size
            // The first card always shows (clamped to the screen); later ones need a slot and the room.
            full = full || (shown > 0 && (shown >= Self.maxVisible || top - size.height < visible.minY + Self.margin))
            if full {
                if panel.isVisible { panel.orderOut(nil) }   // waits for a free slot
                continue
            }
            let y = max(visible.minY + Self.margin, top - size.height)
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            if panel.frame != frame {
                if animated && panel.isVisible {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        panel.animator().setFrame(frame, display: true)
                    }
                } else {
                    panel.setFrame(frame, display: false)
                }
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
            shown += 1
            top -= size.height + Self.gap
        }
    }

    /// Re-applies the Appearance setting to every panel, waiting ones included.
    private func applyAppearance() {
        let appearance = Self.currentAppearance()
        for panel in panels.values where panel.appearance?.name != appearance?.name { panel.appearance = appearance }
    }

    /// The screen under the pointer: that's where the user just clicked the download link.
    private static func activeScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    /// The app's Appearance setting (Settings → General) for a window outside the SwiftUI scenes.
    private static func currentAppearance() -> NSAppearance? {
        switch Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

extension UserDefaults {
    /// The `appearance` default (`@AppStorage("appearance")`), observable with KVO. KVO also sees
    /// changes written by another process, such as `defaults write`.
    @objc dynamic var appearance: String? { string(forKey: "appearance") }
}

/// A small floating window that never activates the app. It has no frame of its own: the SwiftUI
/// content draws the rounded glass card, and the window around it is transparent.
private final class ProgressPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false        // the app is usually in the background
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes the panel.
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Hands the scene's `openWindow` action to the panels, so "Show all" can reopen a closed main window.
struct MainWindowOpenerRegistration: View {
    let panels: CaptureProgressPanels
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let openWindow = openWindow
                panels.openMainWindow = { openWindow(id: "main") }
            }
    }
}
