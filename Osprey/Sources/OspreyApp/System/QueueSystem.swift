import Foundation
import OspreyLibrary

/// The network as "Only on Wi-Fi" reads it.
@MainActor protocol NetworkConditions: AnyObject {
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

    /// The conditions now, with the Debug build's overrides applied.
    var conditions: QueueConditions {
        DebugOverrides.apply(to: QueueConditions(isExpensive: network.isExpensive, isConstrained: network.isConstrained,
                                                 onBattery: power.onBattery))
    }
}
