import AppKit
import OspreyLibrary
import os

/// Named queues: each runs its own downloads, oldest first, up to its "files at once", while its schedule and
/// conditions allow; the rules live in OspreyLibrary (`QueuePlanner`, `QueueFinish`, `SleepPlan`).
extension DownloadManager {
    private static let queueLog = Logger(subsystem: "com.akhanlari.osprey", category: "queues")

    // MARK: Planning

    /// One planning pass. The 250 ms poll calls it, and so do the start/stop timer, wake, clock and time-zone changes,
    /// network and power changes, and every user action that changes what should run.
    /// 1. Each queue's schedule is brought up to now; a queue that just started lets its waiting downloads run.
    /// 2. Downloads of queues that aren't running (stopped, waiting or held) are paused; they keep `wantsToRun`.
    /// 3. Each running queue starts its queued downloads, oldest first, up to its `slots`.
    /// 4. A queue that ran out finishes: it deactivates and, if it finished by itself, runs its after-finish action.
    /// 5. The sleep assertions and the timer follow.
    func scheduleQueue() {
        guard !queueStopped else { return }
        // The network and power watchers start before the first pass, whoever calls it first.
        if queueObservers.isEmpty { startQueueTriggers() }
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let conditions = system.conditions
        var steps = queues.map { queue in
            var queue = queue
            // Main is active while it has work, so it can finish like the others.
            if queue.isMain && !queue.isActive && items.contains(where: { $0.queueID == queue.id && Self.isPending($0) }) {
                queue.isActive = true
                queue.lastStartedAt = now
                completions[queue.id] = []
            }
            return QueuePlanner.step(queue, now: now, calendar: calendar, conditions: conditions)
        }
        for step in steps where step.started { activate(step.queue.id) }
        publish(steps)

        for item in items where item.status == .downloading && !item.heldByQueue && !item.isMerging
            && decisions[item.queueID] != .run {
            item.heldByQueue = true
            item.startRequested = false
            Task { await item.task.pause() }
        }
        for step in steps where step.decision == .run {
            let queue = step.queue
            var running = items.filter { $0.queueID == queue.id && $0.status == .downloading }.count
            for item in items.reversed() where item.queueID == queue.id && item.status == .queued && running < queue.slots {
                start(item)
                running += 1
            }
        }

        var finished: [Queue] = []
        for index in steps.indices where steps[index].queue.isActive {
            let queue = steps[index].queue
            let pending = items.filter { $0.queueID == queue.id && Self.isPending($0) }.count
            let othersBusy = items.contains { other in
                other.queueID != queue.id
                    && (other.status == .downloading || (other.status == .queued && decisions[other.queueID] == .run))
            }
            let outcome = QueueFinish.check(isActive: true, pending: pending,
                                            completedThisActivation: completions[queue.id]?.count ?? 0,
                                            othersBusy: othersBusy)
            guard outcome != .none else { continue }
            steps[index].queue = QueuePlanner.deactivated(queue, now: now)
            steps[index].decision = QueuePlanner.evaluate(steps[index].queue, now: now, calendar: calendar,
                                                          conditions: conditions)
            completions[queue.id] = []
            if case .finished(let runAction) = outcome {
                Self.queueLog.notice("Queue finished; after-finish action \(runAction ? "runs" : "skipped", privacy: .public)")
                if runAction { finished.append(queue) }
            }
        }
        publish(steps)
        // After the queues are saved inactive: Quit may end the app inside this call.
        for queue in finished { system.finishActions.perform(queue.afterFinish, queueName: queue.name) }

        let busy = Set(items.filter { Self.isPending($0) }.map(\.queueID))
        let waiting = Set(items.filter { Self.isWaiting($0) && $0.status != .downloading }.map(\.queueID))
        let needs = SleepPlan.needs(steps, busy: busy, waiting: waiting, onBattery: conditions.onBattery, now: now)
        if needs != sleepNeeds {
            sleepNeeds = needs
            system.sleepGuard.apply(needs)
        }
        armQueueTimer(QueuePlanner.nextEvent(queues, now: now, calendar: calendar))
    }

    /// Queued or running.
    static func isPending(_ item: DownloadItem) -> Bool { item.status == .downloading || item.status == .queued }

    /// A scheduled start (or Start now) began an activation: its downloads saved waiting run, and completions count anew.
    private func activate(_ queueID: UUID) {
        completions[queueID] = []
        for item in items where item.queueID == queueID && item.waitingInQueue {
            item.waitingInQueue = false
            item.wantsToRun = true
        }
    }

    /// Writes the queues and decisions only when they changed: every write to an observed property re-renders the
    /// window, and an idle tick must not.
    private func publish(_ steps: [QueueStep]) {
        let next = steps.map(\.queue)
        if next != queues {
            queues = next
            saveQueues()
        }
        let decided = Dictionary(steps.map { ($0.queue.id, $0.decision) }, uniquingKeysWith: { first, _ in first })
        if decided != decisions { decisions = decided }
    }

    func saveQueues() {
        do {
            try queueStore.save(queues)
        } catch {
            Self.queueLog.error("Couldn't save the queues: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Timer and triggers

    /// Sleeps until `date` (the next start or stop), then plans again. Re-armed only when the date changes.
    private func armQueueTimer(_ date: Date?) {
        guard date != queueTimerDate else { return }
        queueTimerDate = date
        queueTimer?.cancel()
        queueTimer = nil
        guard let date else { return }
        queueTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.queueTimerDate = nil
            self.scheduleQueue()
        }
    }

    /// Plans again after the Mac wakes, the clock or time zone changes, the day changes, or the network or power source
    /// changes. A sleeping timer's wait was measured on the old clock, so it is re-armed.
    func startQueueTriggers() {
        guard queueObservers.isEmpty else { return }
        let replan: @MainActor @Sendable () -> Void = { [weak self] in
            self?.queueTimerDate = nil
            self?.scheduleQueue()
        }
        system.network.start(onChange: replan)
        system.power.start(onChange: replan)
        queueObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { replan() }
            })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            queueObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    NSTimeZone.resetSystemTimeZone()
                    replan()
                }
            })
        }
    }

    // MARK: Queue actions

    func queue(_ id: UUID) -> Queue? { queues.first { $0.id == id } }

    /// "Download later"'s default: Later while it exists, else the first queue after Main, else Main.
    var defaultLaterQueueID: UUID {
        if queues.contains(where: { $0.id == Queue.laterID }) { return Queue.laterID }
        return queues.first { !$0.isMain }?.id ?? Queue.mainID
    }

    /// A new queue, added last. Starts before now count as handled (`QueuePlanner.edited`).
    func addQueue(_ queue: Queue) {
        var queue = QueuePlanner.edited(queue, from: nil, now: Date())
        queue.isMain = false
        queues.append(queue)
        saveQueues()
        scheduleQueue()
    }

    /// Saves an edited queue. Main keeps its id, name rules and no schedule (`QueueStore` enforces it).
    func updateQueue(_ queue: Queue) {
        guard let index = queues.firstIndex(where: { $0.id == queue.id }) else { return }
        queues[index] = QueuePlanner.edited(queue, from: queues[index], now: Date())
        saveQueues()
        queueTimerDate = nil
        scheduleQueue()
    }

    /// Deletes a queue; its downloads move to Main and stay paused or queued as they were. Main can't be deleted.
    func deleteQueue(_ id: UUID) {
        guard id != Queue.mainID, queues.contains(where: { $0.id == id }) else { return }
        queues.removeAll { $0.id == id }
        completions[id] = nil
        for item in items where item.queueID == id {
            item.queueID = Queue.mainID
            item.waitingInQueue = false
            saveNow(item)
        }
        saveQueues()
        scheduleQueue()
    }

    /// Moves a queue up (`-1`) or down (`+1`) among the queues after Main.
    func moveQueue(_ id: UUID, by offset: Int) {
        guard let index = queues.firstIndex(where: { $0.id == id }), !queues[index].isMain else { return }
        let target = index + offset
        guard target >= 1, target < queues.count else { return }
        queues.swapAt(index, target)
        saveQueues()
    }

    /// Start now: the queue becomes active at once, and its paused downloads join the waiting ones (failed ones stay
    /// as they are). Its schedule's later starts still apply.
    func start(queue id: UUID) {
        guard let index = queues.firstIndex(where: { $0.id == id }), !queues[index].isMain, !queues[index].isActive else { return }
        queues[index].isActive = true
        queues[index].lastStartedAt = Date()
        for item in items where item.queueID == id && item.status == .paused {
            item.wantsToRun = true
            saveNow(item)
        }
        activate(id)
        saveQueues()
        scheduleQueue()
    }

    /// Stop: the queue deactivates and its running downloads pause, keeping `wantsToRun`, so Start now or its next
    /// start resumes them. A stopped queue never runs its after-finish action.
    func stop(queue id: UUID) {
        guard let index = queues.firstIndex(where: { $0.id == id }), !queues[index].isMain, queues[index].isActive else { return }
        queues[index] = QueuePlanner.deactivated(queues[index], now: Date())
        completions[id] = []
        saveQueues()
        scheduleQueue()
    }

    /// Move to queue: a running download moved to a queue that isn't running pauses (and runs with that queue).
    func move(_ item: DownloadItem, to queueID: UUID) {
        guard item.queueID != queueID, queues.contains(where: { $0.id == queueID }) else { return }
        item.queueID = queueID
        saveNow(item)
        scheduleQueue()
    }

    // MARK: Sidebar

    /// "Running · 2 of 3", "Starts 2:00 AM", "Waiting for Wi-Fi", "On battery — waiting", "Stopped".
    func statusLine(for queue: Queue) -> String {
        let mine = items.filter { $0.queueID == queue.id }
        return QueueStatusText.line(decisions[queue.id] ?? .stopped, isMain: queue.isMain,
                                    running: mine.filter { $0.status == .downloading }.count,
                                    pending: mine.filter(Self.isPending).count,
                                    now: Date(), calendar: .autoupdatingCurrent)
    }
}
