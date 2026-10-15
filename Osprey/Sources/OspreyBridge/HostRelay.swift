import Foundation

/// Chrome native messaging over stdio: read framed requests until EOF, answer each through the app.
public enum HostRelay {
    public static func run(input: FileHandle, output: FileHandle, origin: String?,
                           send: (BridgeRequest) throws -> BridgeResponse) -> Int32 {
        if let origin, origin != BridgeLocation.chromeExtensionOrigin { return 1 }
        while true {
            let payload: Data
            do {
                guard let next = try Frame.read(from: input) else { return 0 }
                payload = next
            } catch {
                return 1
            }
            let response = BridgeRelay.response(for: payload, send: send)
            do {
                try output.write(contentsOf: Frame.encode(JSONEncoder().encode(response)))
            } catch {
                return 1
            }
        }
    }
}
