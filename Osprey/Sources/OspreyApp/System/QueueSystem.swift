import Foundation
import OspreyLibrary

/// The network as "Only on Wi-Fi" reads it.
@MainActor protocol NetworkConditions: AnyObject {
    /// False until the first network path arrives; the network's state isn't known before then.
    var hasPath: Bool { get }
    /// A phone hotspot (or another network the system marks expensive).
    var isExpensive: Bool { get }
    /// Low Data Mode.
    var isConstrained: Bool { get }
    /// Begins watching; `onChange` runs on the main thread after each change.
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
}

/// The power source as "Only when plugged in" reads it.
@MainActor protocol PowerConditions: AnyObject {
    var onBattery: Bool { get }
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
}

/// Holds or releases the power assertions the queues need.
@MainActor protocol SleepGuarding: AnyObject {
    func apply(_ needs: SleepNeeds)
}

/// Runs a queue's after-finish action.
@MainActor protocol FinishActionPerforming: AnyObject {
    func perform(_ action: Queue.AfterFinish, queueName: String)
    /// Asks for Automation consent to System Events if not yet given; true when Shut down may run.
    func requestShutdownPermission() async -> Bool
    /// Checks without asking; true when Shut down would fail for want of consent.
    func shutdownPermissionMissing() async -> Bool
}

/// Settings › General › Open at login.
@MainActor protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    /// Registered, but the user must still allow it in System Settings › General › Login Items.
    var needsApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// What the scheduler needs from the system, behind small protocols so the rules (OspreyLibrary) stay testable.
@MainActor final class QueueSystem {
    let network: any NetworkConditions
    let power: any PowerConditions
    let sleepGuard: any SleepGuarding
    let finishActions: any FinishActionPerforming

    init(network: any NetworkConditions, power: any PowerConditions, sleepGuard: any SleepGuarding,
         finishActions: any FinishActionPerforming) {
        self.network = network
        self.power = power
        self.sleepGuard = sleepGuard
        self.finishActions = finishActions
    }

    static func live() -> QueueSystem {
        QueueSystem(network: NetworkMonitor(), power: PowerMonitor(), sleepGuard: SleepGuard(), finishActions: FinishActions())
    }

    /// The conditions now, with the Debug build's overrides applied. Before the first network path, the network counts
    /// as expensive, so a Wi-Fi-only queue holds rather than starting on a network that may be a hotspot.
    var conditions: QueueConditions {
        DebugOverrides.apply(to: QueueConditions(isExpensive: network.isExpensive || !network.hasPath,
                                                 isConstrained: network.isConstrained, onBattery: power.onBattery))
    }
}
