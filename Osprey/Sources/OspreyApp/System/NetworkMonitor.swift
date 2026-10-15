import Foundation
import Network

/// `NWPathMonitor` on the main queue. Until the first path arrives (within milliseconds of `start`), `hasPath` is
/// false and `QueueSystem.conditions` counts the network as expensive, so Wi-Fi-only queues hold instead of failing open.
@MainActor final class NetworkMonitor: NetworkConditions {
    private let monitor = NWPathMonitor()
    private(set) var hasPath = false
    private(set) var isExpensive = false
    private(set) var isConstrained = false
    private(set) var isOffline = false
    private var started = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive, constrained = path.isConstrained
            // Only "unsatisfied" is offline: "requiresConnection" (an on-demand VPN) connects when a download asks.
            let offline = path.status == .unsatisfied
            MainActor.assumeIsolated {                   // the monitor runs on the main queue
                guard let self, !self.hasPath || expensive != self.isExpensive || constrained != self.isConstrained
                        || offline != self.isOffline else { return }
                self.hasPath = true
                self.isExpensive = expensive
                self.isConstrained = constrained
                self.isOffline = offline
                onChange()
            }
        }
        monitor.start(queue: .main)
    }

    deinit {
        monitor.cancel()
    }
}
