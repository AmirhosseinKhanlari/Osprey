import Foundation
import Testing

struct WaitTimeout: Error {}

/// Polls `condition` every 50 ms until it holds or `timeout` passes.
func waitUntil(timeout: Duration, _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out after \(timeout)")
    throw WaitTimeout()
}
