import Foundation
import SafariServices
import OspreyBridge

/// Receives `browser.runtime.sendNativeMessage` calls from the Safari extension and relays them to the app.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
        let payload = message.flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil }
        nonisolated(unsafe) let context = context
        DispatchQueue.global(qos: .userInitiated).async {
            // The client's standard timing (BridgeTimeouts) answers within 7.5 s, before background.js gives up at 8 s.
            let client = BridgeClient()
            let response = payload.map { BridgeRelay.response(for: $0, send: client.send) } ?? .failure(.badRequest)
            let item = NSExtensionItem()
            item.userInfo = [SFExtensionMessageKey: Self.dictionary(response)]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func dictionary(_ response: BridgeResponse) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(response),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["v": 1, "ok": false, "error": "internal"]
        }
        return object
    }
}
