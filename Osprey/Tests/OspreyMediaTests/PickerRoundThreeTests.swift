import Foundation
import Testing
@testable import OspreyMedia

@Suite struct PickerRequestTrackerTests {
    @Test func staleDismissalDoesNotCloseANewerRequest() {
        var tracker = PickerRequestTracker()
        let old = UUID(), new = UUID()
        tracker.open(old)
        tracker.open(new)                              // a browser click arrives while the old sheet animates out
        let closed1 = tracker.close(ifCurrent: old)       // the old sheet's onDismiss
        #expect(!closed1)
        #expect(tracker.current == new)
        let closed2 = tracker.close(ifCurrent: new)
        #expect(closed2)
        #expect(tracker.current == nil)
    }

    @Test func nilOrUnknownIDsCloseNothing() {
        var tracker = PickerRequestTracker()
        let id = UUID()
        tracker.open(id)
        let closed3 = tracker.close(ifCurrent: nil)
        #expect(!closed3)
        let closed4 = tracker.close(ifCurrent: UUID())
        #expect(!closed4)
        #expect(tracker.current == id)
        tracker.close()
        #expect(tracker.current == nil)
    }
}

@Suite struct AsyncLimiterTests {
    final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, peak = 0, finished = 0
        func enter() { lock.withLock { now += 1; peak = max(peak, now) } }
        func leave() { lock.withLock { now -= 1; finished += 1 } }
        var values: (peak: Int, finished: Int) { lock.withLock { (peak, finished) } }
    }

    @Test func neverRunsMoreThanTheLimitAcrossCallers() async {
        let limiter = AsyncLimiter(limit: 2)
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<7 {                           // e.g. two playlists' worth of probes at once
                group.addTask {
                    await limiter.withSlot {
                        gauge.enter()
                        try? await Task.sleep(for: .milliseconds(30))
                        gauge.leave()
                    }
                }
            }
        }
        #expect(gauge.values.peak == 2)
        #expect(gauge.values.finished == 7)
    }

    @Test func cancelledWaiterGivesItsSlotBack() async {
        let limiter = AsyncLimiter(limit: 1)
        let gauge = Gauge()
        let holder = Task { await limiter.withSlot { try? await Task.sleep(for: .milliseconds(100)) } }
        try? await Task.sleep(for: .milliseconds(20))
        let waiter = Task { await limiter.withSlot { gauge.enter(); gauge.leave() } }
        waiter.cancel()
        _ = await (holder.value, waiter.value)
        // The limiter is free again: a later caller runs at once.
        await limiter.withSlot { gauge.enter(); gauge.leave() }
        #expect(gauge.values.finished >= 1)
    }
}
