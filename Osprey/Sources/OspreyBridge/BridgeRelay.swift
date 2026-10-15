import Foundation

/// Turns one raw JSON message from a browser into the app's reply.
/// The Chrome host and the Safari extension handler both use it.
public enum BridgeRelay {
    public static func response(for payload: Data, send: (BridgeRequest) throws -> BridgeResponse) -> BridgeResponse {
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: payload) else { return .failure(.badRequest) }
        do { return try send(request) } catch BridgeClientError.notRunning { return .failure(.notRunning) } catch { return .failure(.unavailable) }
    }
}
