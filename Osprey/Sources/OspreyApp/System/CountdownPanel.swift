import AppKit
import IOKit.pwr_mgt
import Observation
import SwiftUI

/// "Mac will sleep in 60 s · Cancel": a small floating panel in the top-right corner that never activates the app.
/// When the count reaches zero it closes and calls `onFinish`, once; Cancel closes it and calls `onCancel`. It never
/// takes keyboard focus from the app the user is in, so it has no Escape shortcut: keys keep going to that app.
///
/// The count runs on `SuspendingClock`, which stands still while the Mac sleeps and ignores wall-clock changes, and it
/// restarts from 60 s on every wake, so the action never runs straight after a wake or a clock jump. While the panel
/// shows, it holds an idle-sleep assertion so idle sleep can't interrupt the count.
@MainActor final class CountdownPanel {
    static let seconds = 60

    private let model: CountdownModel
    private let panel: FloatingPanel
    private var timer: Task<Void, Never>?
    private var deadline = SuspendingClock.now
    private var awake: PowerAssertion?
    private var wakeObserver: (any NSObjectProtocol)?
    private var ended = false
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(action: PowerAction, queueName: String, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model = CountdownModel(action: action, queueName: queueName, remaining: Self.seconds)
        panel = FloatingPanel(size: CGSize(width: 340, height: 92))
        self.onFinish = onFinish
        self.onCancel = onCancel
        let hosting = NSHostingView(rootView: CountdownView(model: model) { [weak self] in self?.cancel() })
        hosting.sizingOptions = [.minSize, .maxSize]
        panel.contentView = hosting
    }

    /// Shows the panel and starts the count. Only the first call does anything.
    func show() {
        guard timer == nil, !ended else { return }
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.layoutIfNeeded()
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 14))
        }
        panel.orderFrontRegardless()
        awake = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                               reason: "Osprey is counting down to \(model.action.verb)")
        restart()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.tick() else { return }
                try? await Task.sleep(for: .milliseconds(250), clock: .suspending)
            }
        }
    }

    /// The action being counted down to.
    var action: PowerAction { model.action }

    /// Switches to a stronger action (Sleep to Shut down) without restarting the count.
    func upgrade(to action: PowerAction, queueName: String) {
        guard !ended, action != model.action else { return }
        model.action = action
        model.queueName = queueName
        if awake != nil {
            awake = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                                   reason: "Osprey is counting down to \(action.verb)")
        }
    }

    func close() {
        ended = true
        timer?.cancel()
        timer = nil
        awake = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        panel.close()
    }

    /// The full count again, from now.
    private func restart() {
        guard !ended else { return }
        deadline = SuspendingClock.now.advanced(by: .seconds(Self.seconds))
        model.remaining = Self.seconds
    }

    /// Updates the shown seconds; finishes at zero. False once the count is over.
    private func tick() -> Bool {
        guard !ended else { return false }
        let left = (deadline - SuspendingClock.now).components
        let seconds = Int(left.seconds) + (left.attoseconds > 0 ? 1 : 0)
        if seconds <= 0 {
            finish()
            return false
        }
        if model.remaining != seconds { model.remaining = seconds }
        return true
    }

    private func cancel() {
        guard !ended else { return }
        close()
        onCancel()
    }

    private func finish() {
        guard !ended else { return }
        close()
        onFinish()
    }
}

@MainActor @Observable final class CountdownModel {
    var action: PowerAction
    var queueName: String
    var remaining: Int

    init(action: PowerAction, queueName: String, remaining: Int) {
        self.action = action
        self.queueName = queueName
        self.remaining = remaining
    }
}

private struct CountdownView: View {
    let model: CountdownModel
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.action.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac will \(model.action.verb) in \(model.remaining) s")
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                Text("“\(model.queueName)” finished.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: cancel)
                .buttonStyle(.capsule(.secondary, height: 30, fontSize: 12.5))
        }
        .padding(.horizontal, 16)
        .frame(width: 340, height: 72)
        .glassPanel(cornerRadius: 18, fill: Theme.panel)
        .padding(10)
        .accessibilityElement(children: .contain)
    }
}

/// A borderless floating panel that never activates the app; the SwiftUI content draws the card.
private final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
