import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct QueuePlannerTests {
    private let fine = QueueConditions()

    private func step(_ queue: Queue, at now: Date, _ conditions: QueueConditions = QueueConditions()) -> QueueStep {
        QueuePlanner.step(queue, now: now, calendar: newYork, conditions: conditions)
    }

    // MARK: Main and manual

    @Test func mainAlwaysRuns() {
        var main = Queue.main
        main.isActive = false
        let result = step(main, at: ny(2026, 10, 15, 9), QueueConditions(isExpensive: true, onBattery: true))
        #expect(result.decision == .run)
        #expect(!result.started)
    }

    @Test func aManualQueueRunsOnlyWhileActive() {
        let idle = Queue(name: "Manual")
        #expect(step(idle, at: ny(2026, 10, 15, 9)).decision == .stopped)
        var active = idle
        active.isActive = true
        active.lastStartedAt = ny(2026, 10, 15, 8)
        let result = step(active, at: ny(2026, 10, 15, 9))
        #expect(result.decision == .run && result.queue.isActive && !result.started)
    }

    // MARK: Once

    @Test func aOnceQueueWaitsForItsStart() {
        let start = ny(2026, 10, 15, 14)
        let result = step(Queue(name: "Once", schedule: .once(start: start)), at: ny(2026, 10, 15, 13, 59))
        #expect(result.decision == .wait(nextStart: start))
        #expect(!result.queue.isActive && !result.started)
    }

    @Test func aOnceQueueStartsAtItsStart() {
        let start = ny(2026, 10, 15, 14)
        let result = step(Queue(name: "Once", schedule: .once(start: start)), at: start)
        #expect(result.decision == .run && result.started)
        #expect(result.queue.isActive && result.queue.lastStartedAt == start)
    }

    @Test func aMissedOnceStartStillCountsInsideItsWindow() {
        let start = ny(2026, 10, 15, 14)
        let queue = Queue(name: "Once", schedule: .once(start: start), lastStartedAt: ny(2026, 10, 15, 9))   // edited at 9
        let result = step(queue, at: ny(2026, 10, 16, 13, 59))          // the Mac slept through it; 23 h 59 min later
        #expect(result.decision == .run && result.started)
        #expect(result.queue.lastStartedAt == start)
    }

    @Test func aOnceQueueAfterItsWindowIsStopped() {
        let start = ny(2026, 10, 15, 14)
        let result = step(Queue(name: "Once", schedule: .once(start: start)), at: ny(2026, 10, 16, 14))
        #expect(result.decision == .stopped && !result.queue.isActive)
    }

    @Test func aOnceQueueWithAStopTimeHasThatWindow() {
        let start = ny(2026, 10, 15, 22)
        let queue = Queue(name: "Once", schedule: .once(start: start), stopTime: hm(1))
        #expect(step(queue, at: ny(2026, 10, 16, 0, 59)).decision == .run)
        #expect(step(queue, at: ny(2026, 10, 16, 1)).decision == .stopped)
    }

    @Test func aHandledStartDoesntStartAgain() {
        let start = ny(2026, 10, 15, 14)
        // It ran and finished (or the user stopped it) inside its window.
        let queue = Queue(name: "Once", schedule: .once(start: start), isActive: false, lastStartedAt: start)
        #expect(step(queue, at: ny(2026, 10, 15, 15)).decision == .stopped)
    }

    // MARK: Daily

    @Test func dailySkipsWeekdaysThatArentChosen() {
        let queue = Queue(name: "Weekdays", schedule: .daily(time: hm(2), weekdays: weekdaysOnly),
                          lastStartedAt: ny(2026, 10, 16, 2))
        // Friday 2026-10-16 at noon: the next weekday start is Monday.
        let result = step(queue, at: ny(2026, 10, 16, 12))
        #expect(result.decision == .wait(nextStart: ny(2026, 10, 19, 2)))
        // A Saturday doesn't start, even inside the window.
        let saturday = Queue(name: "Weekdays", schedule: .daily(time: hm(2), weekdays: weekdaysOnly),
                             lastStartedAt: ny(2026, 10, 16, 2))
        #expect(!step(saturday, at: ny(2026, 10, 17, 3)).queue.isActive)
    }

    @Test func aMissedDailyStartCountsUntilTheEndOfThatDay() {
        let queue = Queue(name: "Nightly", schedule: .daily(time: hm(2), weekdays: everyDay), lastStartedAt: ny(2026, 10, 14, 2))
        let late = step(queue, at: ny(2026, 10, 15, 23, 59))
        #expect(late.started && late.queue.lastStartedAt == ny(2026, 10, 15, 2))
        let tooLate = step(queue, at: ny(2026, 10, 16, 0, 30))           // yesterday's window ended at midnight
        #expect(!tooLate.queue.isActive)
        #expect(tooLate.decision == .wait(nextStart: ny(2026, 10, 16, 2)))
    }

    @Test func aStopTimeAcrossMidnightKeepsTheWindowOpenUntilItAndThenStops() {
        let queue = Queue(name: "Overnight", schedule: .daily(time: hm(23), weekdays: [5]),   // Thursdays at 11 PM
                          stopTime: hm(1), lastStartedAt: ny(2026, 10, 8, 23))
        // Opened Friday 00:30: Thursday's start was missed and its window runs until 1:00.
        let missed = step(queue, at: ny(2026, 10, 16, 0, 30))
        #expect(missed.started && missed.decision == .run)
        #expect(missed.queue.lastStartedAt == ny(2026, 10, 15, 23))
        // At 1:00 it stops, and waits for next Thursday.
        let stopped = step(missed.queue, at: ny(2026, 10, 16, 1))
        #expect(!stopped.queue.isActive && !stopped.started)
        #expect(stopped.decision == .wait(nextStart: ny(2026, 10, 22, 23)))
    }

    @Test func theStopTimeStopsAnActiveQueue() {
        let running = Queue(name: "Nightly", schedule: .daily(time: hm(2), weekdays: everyDay), stopTime: hm(6),
                            isActive: true, lastStartedAt: ny(2026, 10, 15, 2))
        #expect(step(running, at: ny(2026, 10, 15, 5, 59)).decision == .run)
        let stopped = step(running, at: ny(2026, 10, 15, 6))
        #expect(!stopped.queue.isActive)
        #expect(stopped.decision == .wait(nextStart: ny(2026, 10, 16, 2)))
    }

    @Test func aStopTimeEqualToTheStartGivesA24HourWindowAndRestartsAtTheNextStart() {
        let running = Queue(name: "Always", schedule: .daily(time: hm(2), weekdays: everyDay), stopTime: hm(2),
                            isActive: true, lastStartedAt: ny(2026, 10, 15, 2))
        #expect(step(running, at: ny(2026, 10, 16, 1, 59)).decision == .run)
        let next = step(running, at: ny(2026, 10, 16, 2))
        #expect(next.started && next.queue.isActive && next.queue.lastStartedAt == ny(2026, 10, 16, 2))
    }

    @Test func aStopTimeStopsAQueueTheUserStarted() {
        let started = Queue(name: "Manual", stopTime: hm(18), isActive: true, lastStartedAt: ny(2026, 10, 15, 17))
        #expect(step(started, at: ny(2026, 10, 15, 17, 59)).decision == .run)
        #expect(step(started, at: ny(2026, 10, 15, 18)).decision == .stopped)
    }

    // MARK: DST

    @Test func aStartTheClocksSkipRunsAtTheNextTimeThatExists() {
        let queue = Queue(name: "Nightly", schedule: .daily(time: hm(2, 30), weekdays: everyDay))
        // 2026-03-08 2:30 AM doesn't exist in New York: 3:00 AM EDT.
        #expect(QueuePlanner.nextStart(queue, after: ny(2026, 3, 8), calendar: newYork) == utc("2026-03-08T07:00:00Z"))
        // The next day it is 2:30 AM EDT again.
        #expect(QueuePlanner.nextStart(queue, after: utc("2026-03-08T12:00:00Z"), calendar: newYork)
                == utc("2026-03-09T06:30:00Z"))
    }

    @Test func aStartTheClocksRepeatRunsOnceAtTheFirst() {
        let queue = Queue(name: "Nightly", schedule: .daily(time: hm(1, 30), weekdays: everyDay))
        let first = utc("2026-11-01T05:30:00Z")                        // 1:30 AM EDT
        #expect(QueuePlanner.nextStart(queue, after: ny(2026, 11, 1), calendar: newYork) == first)
        // Not again at 1:30 AM EST an hour later: the next start is Monday's.
        #expect(QueuePlanner.nextStart(queue, after: first, calendar: newYork) == utc("2026-11-02T06:30:00Z"))
    }

    @Test func dailyStartsAcrossTheFallBackDayAre25HoursApart() {
        let queue = Queue(name: "Nightly", schedule: .daily(time: hm(2), weekdays: everyDay))
        let saturday = utc("2026-10-31T06:00:00Z")                     // 2:00 AM EDT
        let sunday = QueuePlanner.nextStart(queue, after: saturday, calendar: newYork)
        #expect(sunday == utc("2026-11-01T07:00:00Z"))                 // 2:00 AM EST
        #expect(sunday?.timeIntervalSince(saturday) == 90_000)      // 25 h
    }

    @Test func aMissedStartOnTheSpringForwardDayUsesThatDaysWindow() {
        let queue = Queue(name: "Nightly", schedule: .daily(time: hm(2, 30), weekdays: [1]), lastStartedAt: ny(2026, 3, 1, 2, 30))
        let result = step(queue, at: utc("2026-03-09T03:59:00Z"))      // 11:59 PM EDT on the 8th
        #expect(result.started && result.queue.lastStartedAt == utc("2026-03-08T07:00:00Z"))
        #expect(!step(queue, at: utc("2026-03-09T04:00:00Z")).queue.isActive)   // midnight: the window is over
    }

    // MARK: Conditions

    @Test func unmetConditionsHoldAnActiveQueue() {
        let wifi = Queue(name: "Wi-Fi", onlyOnWiFi: true, isActive: true, lastStartedAt: ny(2026, 10, 15, 8))
        #expect(step(wifi, at: ny(2026, 10, 15, 9), QueueConditions(isExpensive: true)).decision == .hold(reason: .wifi))
        #expect(step(wifi, at: ny(2026, 10, 15, 9), QueueConditions(isConstrained: true)).decision == .hold(reason: .wifi))
        #expect(step(wifi, at: ny(2026, 10, 15, 9), QueueConditions(onBattery: true)).decision == .run)
        let power = Queue(name: "AC", onlyOnAC: true, isActive: true, lastStartedAt: ny(2026, 10, 15, 8))
        #expect(step(power, at: ny(2026, 10, 15, 9), QueueConditions(onBattery: true)).decision == .hold(reason: .power))
        #expect(step(power, at: ny(2026, 10, 15, 9), QueueConditions(isExpensive: true)).decision == .run)
        var both = wifi
        both.onlyOnAC = true
        #expect(step(both, at: ny(2026, 10, 15, 9), QueueConditions(isExpensive: true, onBattery: true)).decision
                == .hold(reason: .wifi))
        #expect(step(both, at: ny(2026, 10, 15, 9), fine).decision == .run)    // met again: it continues
    }

    @Test func beingOfflineHoldsEveryActiveQueueButMain() {
        let manual = Queue(name: "Manual", isActive: true, lastStartedAt: ny(2026, 10, 15, 8))
        let offline = QueueConditions(isOffline: true)
        #expect(step(manual, at: ny(2026, 10, 15, 9), offline).decision == .hold(reason: .offline))
        var wifi = manual
        wifi.onlyOnWiFi = true
        #expect(step(wifi, at: ny(2026, 10, 15, 9), QueueConditions(isExpensive: true, isOffline: true)).decision
                == .hold(reason: .offline))
        #expect(step(.main, at: ny(2026, 10, 15, 9), offline).decision == .run)
        #expect(step(manual, at: ny(2026, 10, 15, 9), fine).decision == .run)    // back online: it continues
    }

    @Test func conditionsDontHoldAQueueThatIsntActive() {
        let queue = Queue(name: "Wi-Fi", onlyOnWiFi: true)
        #expect(step(queue, at: ny(2026, 10, 15, 9), QueueConditions(isExpensive: true)).decision == .stopped)
    }

    // MARK: Timer, editing, time helpers

    @Test func theNextEventIsTheSoonestStartOrStop() {
        let now = ny(2026, 10, 15, 1)
        let nightly = Queue(name: "Nightly", schedule: .daily(time: hm(2), weekdays: everyDay), lastStartedAt: ny(2026, 10, 14, 2))
        let running = Queue(name: "Manual", stopTime: hm(1, 30), isActive: true, lastStartedAt: ny(2026, 10, 15, 0, 45))
        #expect(QueuePlanner.nextEvent([.main, nightly], now: now, calendar: newYork) == ny(2026, 10, 15, 2))
        #expect(QueuePlanner.nextEvent([.main, nightly, running], now: now, calendar: newYork) == ny(2026, 10, 15, 1, 30))
        #expect(QueuePlanner.nextEvent([.main, .later], now: now, calendar: newYork) == nil)
    }

    @Test func aQueueScheduledAfterTodaysStartWaitsForTomorrow() {
        let now = ny(2026, 10, 15, 15)
        let made = QueuePlanner.edited(Queue(name: "Nightly", schedule: .daily(time: hm(2), weekdays: everyDay)),
                                       from: nil, now: now)
        #expect(made.lastStartedAt == now)
        #expect(step(made, at: ny(2026, 10, 15, 15, 1)).decision == .wait(nextStart: ny(2026, 10, 16, 2)))
        var renamed = made
        renamed.name = "Night"
        renamed.lastStartedAt = ny(2026, 10, 14, 2)
        // A rename keeps what was handled; a new schedule counts everything until now as handled.
        #expect(QueuePlanner.edited(renamed, from: made, now: ny(2026, 10, 15, 16)).lastStartedAt == ny(2026, 10, 14, 2))
        var moved = renamed
        moved.schedule = .daily(time: hm(3), weekdays: everyDay)
        #expect(QueuePlanner.edited(moved, from: renamed, now: ny(2026, 10, 15, 16)).lastStartedAt == ny(2026, 10, 15, 16))
    }

    @Test func aStopOrFinishAfterAStartPassedDoesntStartAgain() {
        // Started by hand at 1:00; the daily 2:00 start passed while it ran; stopped (or finished) at 2:30.
        let running = Queue(name: "Nightly", schedule: .daily(time: hm(2), weekdays: everyDay), isActive: true,
                            lastStartedAt: ny(2026, 10, 15, 1))
        let stopped = QueuePlanner.deactivated(running, now: ny(2026, 10, 15, 2, 30))
        #expect(!stopped.isActive && stopped.lastStartedAt == ny(2026, 10, 15, 2, 30))
        let next = step(stopped, at: ny(2026, 10, 15, 2, 31))
        #expect(!next.queue.isActive && next.decision == .wait(nextStart: ny(2026, 10, 16, 2)))
    }

    @Test func minutesAndInstantsRoundTrip() {
        let date = ny(2026, 10, 15, 21, 45)
        #expect(QueuePlanner.minutes(of: date, calendar: newYork) == hm(21, 45))
        #expect(QueuePlanner.instant(minutes: hm(21, 45), on: ny(2026, 10, 15, 8), calendar: newYork) == date)
    }
}
