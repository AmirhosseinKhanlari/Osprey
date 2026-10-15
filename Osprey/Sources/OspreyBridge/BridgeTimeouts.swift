import Foundation

/// The time limits of one capture, end to end. They nest, so a late `taken:true` can never reach a
/// browser that already gave up and resumed its own download:
///
///     handler (3 s)  <  reply wait (3.5 s)
///     launch wait (4 s) + reply wait (3.5 s)  =  capture budget (7.5 s)  <  extension timeout (8 s)
public enum BridgeTimeouts {
    /// How long the Chrome and Safari extensions wait for a capture reply (`CAPTURE_TIMEOUT_MS` in rules.js).
    public static let extensionCapture: TimeInterval = 8
    /// Everything the client does for one capture: launching the app, connecting, sending and the reply.
    public static let captureBudget: TimeInterval = 7.5
    /// The longest the client polls for the socket after launching the app.
    public static let launchWait: TimeInterval = 4
    /// The longest the client waits for a reply once connected.
    public static let replyWait: TimeInterval = 3.5
    /// How long the app's handler may run before the server answers `internal` (unless it committed).
    public static let handler: TimeInterval = 3
}
