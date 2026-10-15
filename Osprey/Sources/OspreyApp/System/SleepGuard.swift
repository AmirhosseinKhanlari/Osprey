import Foundation
import IOKit.pwr_mgt
import OspreyLibrary

/// IOKit power assertions: no system sleep while a keep-awake queue runs; no idle sleep while one waits for a start
/// due within 12 h on AC power. The display may still sleep. Each is released as soon as it isn't needed.
@MainActor final class SleepGuard: SleepGuarding {
    private var system: IOPMAssertionID?
    private var idle: IOPMAssertionID?

    func apply(_ needs: SleepNeeds) {
        system = Self.hold(system, needs.preventSystemSleep, type: kIOPMAssertionTypePreventSystemSleep,
                           reason: "Osprey is downloading a queue")
        idle = Self.hold(idle, needs.preventIdleSleep, type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                         reason: "Osprey is waiting to start a queue")
    }

    private static func hold(_ current: IOPMAssertionID?, _ wanted: Bool, type: String, reason: String) -> IOPMAssertionID? {
        switch (current, wanted) {
        case (nil, true):
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString, &id)
            return result == kIOReturnSuccess ? id : nil
        case (let id?, false):
            IOPMAssertionRelease(id)
            return nil
        default:
            return current
        }
    }
}
