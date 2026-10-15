import Foundation
import IOKit.pwr_mgt
import OspreyLibrary

/// IOKit power assertions: no system sleep while a keep-awake queue runs; no idle sleep while one waits for a start
/// due within 12 h on AC power. The display may still sleep. Each is released as soon as it isn't needed.
@MainActor final class SleepGuard: SleepGuarding {
    private var system: PowerAssertion?
    private var idle: PowerAssertion?

    func apply(_ needs: SleepNeeds) {
        system = needs.preventSystemSleep
            ? system ?? PowerAssertion(type: kIOPMAssertionTypePreventSystemSleep, reason: "Osprey is downloading a queue")
            : nil
        idle = needs.preventIdleSleep
            ? idle ?? PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                                     reason: "Osprey is waiting to start a queue")
            : nil
    }
}

/// One IOKit power assertion, held from `init` until the object is released.
final class PowerAssertion: Sendable {
    private let id: IOPMAssertionID

    /// Nil when IOKit refuses the assertion.
    init?(type: String, reason: String) {
        var id = IOPMAssertionID(0)
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString,
                                          &id) == kIOReturnSuccess else { return nil }
        self.id = id
    }

    deinit {
        IOPMAssertionRelease(id)
    }
}
