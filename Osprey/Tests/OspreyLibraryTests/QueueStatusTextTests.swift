import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct QueueStatusTextTests {
    private let now = ny(2026, 10, 15, 15)        // a Thursday
    private let posix = Locale(identifier: "en_US_POSIX")

    private func line(_ decision: QueueDecision, isMain: Bool = false, running: Int = 0, pending: Int = 0,
                      waiting: Int = 1) -> String {
        // Formatters put a narrow no-break space before AM/PM; compare with a plain one.
        QueueStatusText.line(decision, isMain: isMain, running: running, pending: pending, waiting: waiting, now: now,
                             calendar: newYork, locale: posix).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func runningShowsHowManyOfTheRest() {
        #expect(line(.run, running: 2, pending: 3) == "Running · 2 of 3")
        #expect(line(.run, isMain: true) == "Ready")
        #expect(line(.run) == "Running")
    }

    @Test func waitingShowsTheStart() {
        #expect(line(.wait(nextStart: ny(2026, 10, 15, 23))) == "Starts 11:00 PM")
        #expect(line(.wait(nextStart: ny(2026, 10, 16, 2))) == "Starts tomorrow 2:00 AM")
        #expect(line(.wait(nextStart: ny(2026, 10, 20, 2))) == "Starts Tue 2:00 AM")
        #expect(line(.wait(nextStart: ny(2026, 10, 30, 2))) == "Starts Oct 30 at 2:00 AM")
    }

    @Test func aScheduledQueueWithNothingWaitingSaysSo() {
        #expect(line(.wait(nextStart: ny(2026, 10, 16, 2)), waiting: 0) == "Nothing waiting")
        #expect(line(.wait(nextStart: ny(2026, 10, 16, 2)), waiting: 2) == "Starts tomorrow 2:00 AM")
        #expect(line(.stopped, waiting: 0) == "Stopped")
    }

    @Test func holdsAndStopsSaySo() {
        #expect(line(.hold(reason: .wifi)) == "Waiting for Wi-Fi")
        #expect(line(.hold(reason: .power)) == "On battery — waiting")
        #expect(line(.hold(reason: .offline)) == "Offline — waiting")
        #expect(line(.stopped) == "Stopped")
    }
}
