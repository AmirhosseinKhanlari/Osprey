import Foundation
import OspreyEngine

/// What a file download shows when resuming fails. A `DownloadJob` reports a failure as text (`DownloadState.failed`),
/// so the engine's own texts are matched here.
public enum ResumeFailureText {
    public static let changedOnServer = "Changed on the server — Restart"
    public static let needsSignIn = "Needs sign-in — download it again from your browser"

    /// The file changed on the server since the partial download began: only starting over helps.
    public static func isChangedOnServer(_ engineMessage: String) -> Bool {
        engineMessage == EngineError.remoteFileChanged.errorDescription
    }

    /// The text to show instead of `engineMessage`, or nil to show it as it is. A 401 or 403 means "sign in again" only
    /// for a download restored from the saved list without stored cookies; a live download has its cookies in memory.
    public static func message(for engineMessage: String, restored: Bool, hasStoredCredentials: Bool) -> String? {
        if isChangedOnServer(engineMessage) { return changedOnServer }
        let refused = [401, 403].contains { engineMessage == EngineError.httpStatus($0, retryAfter: nil).errorDescription }
        if refused, restored, !hasStoredCredentials { return needsSignIn }
        return nil
    }
}
