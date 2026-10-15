import AppKit
import OspreyLibrary
import UserNotifications

/// A queue's after-finish action:
/// - Notify: a notification.
/// - Quit: quits Osprey (the usual quit: downloads pause and the list is saved).
/// - Sleep, Shut down: a 60 s countdown panel with Cancel first. Sleep runs `pmset sleepnow`; Shut down asks System
///   Events over Apple Events, which asks the user for Automation consent once. A Debug build only logs them.
@MainActor final class FinishActions: FinishActionPerforming {
    private var countdown: CountdownPanel?

    func perform(_ action: Queue.AfterFinish, queueName: String) {
        switch action {
        case .nothing:
            break
        case .notify:
            notify(title: "“\(queueName)” finished", body: "Its downloads are done.")
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            startCountdown(.sleep, queueName: queueName)
        case .shutdown:
            startCountdown(.shutDown, queueName: queueName)
        }
    }

    private func startCountdown(_ action: PowerAction, queueName: String) {
        countdown?.close()
        countdown = CountdownPanel(action: action, queueName: queueName) { [weak self] in
            self?.countdown = nil
            self?.run(action)
        } onCancel: { [weak self] in
            self?.countdown = nil
        }
        countdown?.show()
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
            var error: NSDictionary?
            NSAppleScript(source: #"tell application "System Events" to shut down"#)?.executeAndReturnError(&error)
            if error != nil {
                notify(title: "Osprey couldn’t shut down your Mac",
                       body: "Allow Osprey to control System Events in System Settings › Privacy & Security › Automation.")
            }
        }
    }

    private func notify(title: String, body: String) {
        guard CaptureNotifier.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .shutDown: "power"
        }
    }
}
