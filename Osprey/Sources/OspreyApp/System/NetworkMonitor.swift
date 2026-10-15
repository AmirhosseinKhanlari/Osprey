import Foundation
import Network

/// `NWPathMonitor` on the main queue.
@MainActor final class NetworkMonitor: NetworkConditions {
    private let monitor = NWPathMonitor()
    private(set) var isExpensive = false
    private(set) var isConstrained = false
    private var started = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive, constrained = path.isConstrained
            MainActor.assumeIsolated {                   // the monitor runs on the main queue
                guard let self, expensive != self.isExpensive || constrained != self.isConstrained else { return }
                self.isExpensive = expensive
                self.isConstrained = constrained
                onChange()
            }
        }
        monitor.start(queue: .main)
    }
}
