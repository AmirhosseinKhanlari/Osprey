/// Notification wording for a captured download. Private-window captures never name the file or URL,
/// because Notification Center persists notifications and shows them on the lock screen.
public enum CaptureNotificationText {
    public static func title(fileName: String, isPrivate: Bool) -> String {
        isPrivate ? "Downloading a file" : "Downloading \(fileName)"
    }
}
