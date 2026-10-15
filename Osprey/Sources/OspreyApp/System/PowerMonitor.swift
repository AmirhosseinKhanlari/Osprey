import Foundation
import IOKit.ps

/// AC power or battery, from IOKit's power sources, with a run-loop notification on every change.
@MainActor final class PowerMonitor: PowerConditions {
    private(set) var onBattery = PowerMonitor.readOnBattery()
    private var source: CFRunLoopSource?
    private var onChange: (@MainActor @Sendable () -> Void)?

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard source == nil else { return }
        self.onChange = onChange
        // Lives as long as the app (the download manager owns it), so an unretained pointer is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {                   // added to the main run loop below
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
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
