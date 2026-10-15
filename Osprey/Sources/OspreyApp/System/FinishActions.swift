import AppKit
import CoreServices
import OspreyLibrary
import UserNotifications

/// A queue's after-finish action:
/// - Notify: a notification.
/// - Quit: quits Osprey (the usual quit: downloads pause and the list is saved).
/// - Sleep, Shut down: a 60 s countdown panel with Cancel first. Sleep runs `pmset sleepnow`; Shut down sends System
///   Events its Shut down command, which needs the user's Automation consent once. A Debug build only logs them. When
///   the count ends, `canProceed` is asked again: if downloads run again (a capture, a scheduled start), nothing runs
///   and a notification says so.
/// - While a countdown runs, only a stronger action changes it (Shut down > Sleep > Quit), and the count keeps its time.
@MainActor final class FinishActions: FinishActionPerforming {
    private var countdown: CountdownPanel?
    private var canProceed: @MainActor () -> Bool = { true }

    func perform(_ action: Queue.AfterFinish, queueName: String, canProceed: @escaping @MainActor () -> Bool) {
        switch action {
        case .nothing:
            break
        case .notify:
            notify(title: "“\(queueName)” finished", body: "Its downloads are done.")
        case .quit:
            guard countdown == nil else {
                NSLog("Osprey: “%@” finished; Quit skipped, a stronger countdown is running", queueName)
                return
            }
            NSApp.terminate(nil)
        case .sleep:
            startCountdown(.sleep, queueName: queueName, canProceed: canProceed)
        case .shutdown:
            startCountdown(.shutDown, queueName: queueName, canProceed: canProceed)
        }
    }

    /// Asks the user, if they haven't answered yet, to let Osprey control System Events, and says whether it may. The
    /// queue editor calls this when Shut down is chosen, so the question comes while the user is there. The consent
    /// prompt blocks its thread until answered, so it runs off the main thread.
    func requestShutdownPermission() async -> Bool {
        guard await SystemEvents.launch() else { return false }
        return await SystemEvents.offMain { SystemEvents.permission(askUserIfNeeded: true) } == noErr
    }

    /// Whether Shut down may run, without ever asking. The queue editor calls this when it opens on a queue set to
    /// Shut down.
    func shutdownPermission() async -> ShutdownPermission {
        guard await SystemEvents.launch() else { return .unknown }
        switch await SystemEvents.offMain({ SystemEvents.permission(askUserIfNeeded: false) }) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    private func startCountdown(_ action: PowerAction, queueName: String, canProceed: @escaping @MainActor () -> Bool) {
        self.canProceed = canProceed
        if let countdown {
            if action.strength > countdown.action.strength { countdown.upgrade(to: action, queueName: queueName) }
            return                                       // the running count keeps its time
        }
        let panel = CountdownPanel(action: action, queueName: queueName) { [weak self] in
            guard let self, let action = self.countdown?.action else { return }
            self.countdown = nil
            self.proceed(action)
        } onCancel: { [weak self] in
            self?.countdown = nil
        }
        countdown = panel
        panel.show()
    }

    /// The count is over: runs `action` unless downloads are running again.
    private func proceed(_ action: PowerAction) {
        guard canProceed() else {
            NSLog("Osprey: didn't %@ — downloads were still running", action.verb)
            switch action {
            case .sleep: notify(title: "Osprey didn’t put your Mac to sleep", body: "Downloads were still running.")
            case .shutDown: notify(title: "Osprey didn’t shut down your Mac", body: "Downloads were still running.")
            }
            return
        }
        run(action)
    }

    private func run(_ action: PowerAction) {
        if DebugOverrides.powerActionsAreDryRun {
            NSLog("Osprey: Debug dry run — would %@ now", action.verb)
            return
        }
        switch action {
        case .sleep:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            do { try process.run() } catch { NSLog("Osprey: couldn't put the Mac to sleep: %@", error.localizedDescription) }
        case .shutDown:
            Task { await shutDown() }
        }
    }

    /// After the countdown nobody may be there, so this never asks: a consent prompt answered hours later would shut
    /// the Mac down with no warning. Without consent given earlier (in the queue editor) it only notifies.
    private func shutDown() async {
        var allowed = await SystemEvents.launch()
        if allowed { allowed = await SystemEvents.offMain({ SystemEvents.permission(askUserIfNeeded: false) }) == noErr }
        guard allowed else {
            notify(title: "Osprey couldn’t shut down your Mac",
                   body: "Allow Osprey to control System Events in Privacy & Security → Automation.")
            return
        }
        if let failure = await SystemEvents.offMain({ SystemEvents.sendShutDown() }) {
            NSLog("Osprey: couldn't shut down: %@", failure)
            notify(title: "Osprey couldn’t shut down your Mac", body: failure)
        }
    }

    /// Notification permission is asked for at launch (`CaptureNotifier.requestAuthorization()`), not here.
    private func notify(title: String, body: String) {
        guard CaptureNotifier.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
    }
}

/// System Events' Shut down command, sent as a raw Apple Event so it can run off the main thread.
private enum SystemEvents {
    static let bundleID = "com.apple.systemevents"
    /// The command's code in System Events' scripting dictionary (`fndrshut`).
    static let eventClass = fourCharCode("fndr")
    static let eventID = fourCharCode("shut")

    /// Starts System Events in the background if it isn't running (Apple Events reach only running apps), then waits
    /// up to 5 s for it to accept events.
    @MainActor static func launch() async -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            do { try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) } catch { return false }
        }
        for _ in 0..<20 {
            if await offMain({ permission(askUserIfNeeded: false) }) != OSStatus(procNotFound) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// `noErr` when allowed; `errAEEventNotPermitted` when denied; `errAEEventWouldRequireUserConsent` when not yet
    /// asked and `askUserIfNeeded` is false; `procNotFound` when System Events isn't running. Blocks while the consent
    /// prompt is up.
    nonisolated static func permission(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(address, eventClass, eventID, askUserIfNeeded)
    }

    /// Nil on success, otherwise what went wrong.
    nonisolated static func sendShutDown() -> String? {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try event.sendEvent(options: [.waitForReply], timeout: 30)
            return nil
        } catch let error as NSError where error.code == Int(errAETimeout) {
            return nil                                   // shutting down can outlast the reply
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs `work` on a utility queue, off the main thread and the Swift concurrency pool (it may block on a prompt).
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}

/// Sleep or Shut down, after the countdown.
enum PowerAction {
    case sleep, shutDown

    var verb: String {
        switch self {
        case .sleep: "sleep"
        case .shutDown: "shut down"
        }
    }

    /// Shut down beats Sleep (and both beat Quit).
    var strength: Int {
        switch self {
        case .sleep: 1
        case .shutDown: 2
        }
    }

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .shutDown: "power"
        }
    }
}
