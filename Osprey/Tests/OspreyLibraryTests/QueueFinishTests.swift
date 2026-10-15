import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct QueueFinishTests {
    @Test func aQueueThatRanOutFinishesByItself() {
        #expect(QueueFinish.check(isActive: true, pending: 0, completedThisActivation: 2, othersBusy: false)
                == .finished(runAction: true))
    }

    @Test func otherQueuesStillRunningSkipTheAction() {
        #expect(QueueFinish.check(isActive: true, pending: 0, completedThisActivation: 1, othersBusy: true)
                == .finished(runAction: false))
    }

    @Test func aStoppedQueueNeverFinishes() {
        // Stop clears isActive before its downloads pause, so the queue is never seen as run out.
        #expect(QueueFinish.check(isActive: false, pending: 0, completedThisActivation: 3, othersBusy: false) == .none)
    }

    @Test func aQueueWithWorkLeftKeepsGoing() {
        #expect(QueueFinish.check(isActive: true, pending: 1, completedThisActivation: 3, othersBusy: false) == .none)
    }

    @Test func aQueueWithNothingCompletedEndsQuietly() {
        // Started empty, or everything failed: failures never block finishing, but there is nothing to report.
        #expect(QueueFinish.check(isActive: true, pending: 0, completedThisActivation: 0, othersBusy: false) == .emptied)
    }
}

@Suite struct SleepPlanTests {
    private let now = ny(2026, 10, 15, 15)

    private func step(_ queue: Queue, _ decision: QueueDecision) -> QueueStep {
        QueueStep(queue: queue, decision: decision, started: false)
    }

    @Test func aRunningKeepAwakeQueuePreventsSystemSleep() {
        let awake = Queue(name: "Awake", keepAwake: true, isActive: true)
        let plain = Queue(name: "Plain", isActive: true)
        #expect(SleepPlan.needs([step(awake, .run)], busy: [awake.id], waiting: [], onBattery: false, now: now)
                == SleepNeeds(preventSystemSleep: true))
        #expect(SleepPlan.needs([step(awake, .run)], busy: [], waiting: [], onBattery: false, now: now) == SleepNeeds())
        #expect(SleepPlan.needs([step(plain, .run)], busy: [plain.id], waiting: [], onBattery: false, now: now) == SleepNeeds())
        #expect(SleepPlan.needs([step(awake, .hold(reason: .power))], busy: [awake.id], waiting: [], onBattery: true, now: now)
                == SleepNeeds())
    }

    @Test func aStartWithin12HoursOnACPreventsIdleSleep() {
        let awake = Queue(name: "Nightly", keepAwake: true)
        let soon = step(awake, .wait(nextStart: now.addingTimeInterval(11 * 3600)))
        let later = step(awake, .wait(nextStart: now.addingTimeInterval(13 * 3600)))
        #expect(SleepPlan.needs([soon], busy: [], waiting: [awake.id], onBattery: false, now: now)
                == SleepNeeds(preventIdleSleep: true))
        #expect(SleepPlan.needs([later], busy: [], waiting: [awake.id], onBattery: false, now: now) == SleepNeeds())
        #expect(SleepPlan.needs([soon], busy: [], waiting: [awake.id], onBattery: true, now: now) == SleepNeeds())
        #expect(SleepPlan.needs([soon], busy: [], waiting: [], onBattery: false, now: now) == SleepNeeds())
    }
}
