import Foundation
import Testing
@testable import OspreyLibrary

@Suite struct QuitSequenceTests {
    @Test func everyTaskIsPausedBeforeTheListIsSaved() async {
        let log = EventLog()
        let tasks = [FakeTask(log: log), FakeTask(log: log), FakeTask(log: log)]
        let finished = await QuitSequence.run(tasks.map { QuitItem(task: $0, isPrivate: false) },
                                              persist: { log.append("persist") }, flush: { log.append("flush") })
        #expect(finished)
        for task in tasks {
            #expect(await task.pauses == 1)
            #expect(await task.discards == 0)
        }
        #expect(log.events == ["pause", "pause", "pause", "persist", "flush"])
    }

    @Test func privateDownloadsAreDiscarded() async {
        let normal = FakeTask(), secret = FakeTask()
        _ = await QuitSequence.run([QuitItem(task: normal, isPrivate: false), QuitItem(task: secret, isPrivate: true)],
                                   persist: {}, flush: {})
        #expect(await secret.discards == 1)
        #expect(await secret.pauses == 0)
        #expect(await normal.pauses == 1)
        #expect(await normal.discards == 0)
    }

    @Test func theFlushComesBeforeTheReply() async {
        let log = EventLog()
        _ = await QuitSequence.run([QuitItem(task: FakeTask(log: log), isPrivate: true)],
                                   persist: { log.append("persist") }, flush: { log.append("flush") })
        log.append("reply")                                 // what the app delegate does next
        #expect(log.events == ["discard", "persist", "flush", "reply"])
    }

    @Test func aStuckTaskCannotHoldTheQuitPastTheTimeout() async {
        let log = EventLog()
        let stuck = FakeTask(hang: .seconds(30), log: log)
        let clock = ContinuousClock()
        let start = clock.now
        let finished = await QuitSequence.run([QuitItem(task: stuck, isPrivate: false)], timeout: .milliseconds(300),
                                              persist: { log.append("persist") }, flush: { log.append("flush") })
        #expect(!finished)
        #expect(clock.now - start < .seconds(2))
        #expect(log.events == ["flush"])                    // what is on disk is saved; nothing waits for the stuck task
    }
}
