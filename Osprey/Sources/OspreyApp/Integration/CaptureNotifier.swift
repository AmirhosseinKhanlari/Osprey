import Foundation
import OspreyIntegration
import OspreyMedia
import UserNotifications

/// Posts "Downloading …" notifications. A bare SwiftPM executable has no bundle and can't use
/// UserNotifications, so outside an .app bundle this does nothing.
enum CaptureNotifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func notifyCaptured(fileName: String, isPrivate: Bool) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = CaptureNotificationText.title(fileName: fileName, isPrivate: isPrivate)
        content.body = "Osprey took over this download from your browser."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Playlist entries that couldn't be added after the picker closed. A private request's notification names
    /// neither the playlist nor its videos.
    static func notifyPlaylistFailures(playlist: String, failures: [PlaylistFailure], isPrivate: Bool, kind: MediaKind) {
        guard isAvailable, !failures.isEmpty else { return }
        let content = UNMutableNotificationContent()
        let text = PlaylistFailure.notificationText(playlist: playlist, failures: failures, isPrivate: isPrivate, kind: kind)
        content.title = text.title
        content.body = text.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
