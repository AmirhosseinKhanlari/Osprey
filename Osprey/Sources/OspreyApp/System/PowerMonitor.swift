import Foundation
import IOKit.ps

/// AC power or battery, from IOKit's power sources, with a run-loop notification on every change.
@MainActor final class PowerMonitor: PowerConditions {
    private(set) var onBattery = PowerMonitor.readOnBattery()
    private var registration: PowerSourceRegistration?
    private var onChange: (@MainActor @Sendable () -> Void)?

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard registration == nil else { return }
        self.onChange = onChange
        registration = PowerSourceRegistration { [weak self] in self?.refresh() }
    }

    /// Stops watching. Releasing the monitor stops it too.
    func stop() {
        registration = nil
        onChange = nil
    }

    private func refresh() {
        let now = Self.readOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        onChange?()
    }

    /// A Mac without a battery is always on AC power.
    nonisolated static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// IOKit's power-source run-loop source on the main run loop. The source's context retains its handler, which holds
/// only a weak monitor. On release the source is invalidated (which removes it from the run loop, so it never fires
/// again), and the context is released on the main queue, after any callback already running there has returned. A
/// callback therefore never reaches freed memory.
private final class PowerSourceRegistration {
    private final class Handler: Sendable {
        let call: @MainActor @Sendable () -> Void
        init(_ call: @escaping @MainActor @Sendable () -> Void) { self.call = call }
    }

    private let source: CFRunLoopSource
    private let context: Unmanaged<Handler>

    init?(_ call: @escaping @MainActor @Sendable () -> Void) {
        let context = Unmanaged.passRetained(Handler(call))
        guard let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let handler = Unmanaged<Handler>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { handler.call() }  // the source is on the main run loop
        }, context.toOpaque())?.takeRetainedValue() else {
            context.release()
            return nil
        }
        self.source = source
        self.context = context
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        CFRunLoopSourceInvalidate(source)
        let context = context
        DispatchQueue.main.async { context.release() }
    }
}
