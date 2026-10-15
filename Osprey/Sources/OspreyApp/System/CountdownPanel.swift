import AppKit
import Observation
import SwiftUI

/// "Mac will sleep in 60 s · Cancel": a small floating panel in the top-right corner that never activates the app.
/// When the count reaches zero it closes and calls `onFinish`; Cancel (or Escape) closes it and calls `onCancel`.
@MainActor final class CountdownPanel {
    static let seconds = 60

    private let model: CountdownModel
    private let panel: FloatingPanel
    private var timer: Task<Void, Never>?
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
        panel.onEscape = { [weak self] in self?.cancel() }
    }

    func show() {
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.layoutIfNeeded()
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 14))
        }
        panel.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(TimeInterval(Self.seconds))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
                guard let self else { return }
                if left <= 0 {
                    self.finish()
                    return
                }
                if self.model.remaining != left { self.model.remaining = left }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func close() {
        timer?.cancel()
        timer = nil
        panel.close()
    }

    private func cancel() {
        close()
        onCancel()
    }

    private func finish() {
        close()
        onFinish()
    }
}

@MainActor @Observable final class CountdownModel {
    let action: PowerAction
    let queueName: String
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
                .keyboardShortcut(.cancelAction)
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
    var onEscape: (() -> Void)?

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
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
