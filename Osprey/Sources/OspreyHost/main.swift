import Foundation
import OspreyBridge

// Chrome launches the host with the calling extension's origin as an argument.
let origin = CommandLine.arguments.dropFirst().first { $0.hasPrefix("chrome-extension://") }
// A closed stdout must surface as a write error (exit 1), not kill the process.
signal(SIGPIPE, SIG_IGN)
let client = BridgeClient()
exit(HostRelay.run(input: .standardInput, output: .standardOutput, origin: origin, send: client.send))
