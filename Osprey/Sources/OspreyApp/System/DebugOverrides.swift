import Foundation
import OspreyLibrary

/// Debug builds only, so live checks need no hotspot, no unplugging, and never sleep or shut down the Mac:
/// - `OspreyDebugExpensive`: the network counts as expensive (a hotspot).
/// - `OspreyDebugOnBattery`: the Mac counts as on battery.
/// - Sleep and Shut down only log `Osprey: Debug dry run — would sleep now` (or `shut down`) when their countdown ends.
///
/// Set them at launch (`-OspreyDebugExpensive YES`) or while running
/// (`defaults write com.akhanlari.osprey OspreyDebugExpensive -bool YES`; the 250 ms poll reads them). A Release build
/// ignores them.
enum DebugOverrides {
    static let expensiveKey = "OspreyDebugExpensive"
    static let onBatteryKey = "OspreyDebugOnBattery"

    static func apply(to conditions: QueueConditions) -> QueueConditions {
        #if DEBUG
        var conditions = conditions
        if UserDefaults.standard.bool(forKey: expensiveKey) { conditions.isExpensive = true }
        if UserDefaults.standard.bool(forKey: onBatteryKey) { conditions.onBattery = true }
        return conditions
        #else
        return conditions
        #endif
    }

    /// True in a Debug build: Sleep and Shut down are logged, never performed.
    static var powerActionsAreDryRun: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
