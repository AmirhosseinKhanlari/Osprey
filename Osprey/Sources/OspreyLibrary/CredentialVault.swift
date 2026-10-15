import Foundation
import OspreyEngine
import Security

/// Where a download's sign-in headers (`Cookie`, `Authorization`) are kept while it is unfinished. `CredentialVault` is the
/// Keychain; tests use an in-memory fake.
public protocol CredentialStoring: Sendable {
    /// Keeps the non-empty `Cookie` and `Authorization` values of `headers` for download `id`, replacing what it had.
    /// Returns false, keeping nothing, when there are none.
    @discardableResult func store(id: UUID, headers: [String: String]) throws -> Bool
    /// The stored headers, or an empty dictionary.
    func headers(id: UUID) -> [String: String]
    func delete(id: UUID)
    /// Deletes every item except those of `keep` (at launch: orphans a crash left behind).
    func deleteAll(except keep: Set<UUID>)
}

/// Generic-password items in the login keychain: service `com.akhanlari.osprey.download-credentials`, account = the
/// download id, value = the headers as JSON. The file-based keychain needs no entitlement, so the same code runs in the
/// signed app and (when the Keychain allows it) in an unsigned test binary.
public struct CredentialVault: CredentialStoring {
    /// A Debug build uses its own service (`….debug`), so it never reads or prunes the installed app's items.
    #if DEBUG
    public static let defaultService = "com.akhanlari.osprey.download-credentials.debug"
    #else
    public static let defaultService = "com.akhanlari.osprey.download-credentials"
    #endif

    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
    }

    public let service: String

    public init(service: String = CredentialVault.defaultService) {
        self.service = service
    }

    @discardableResult
    public func store(id: UUID, headers: [String: String]) throws -> Bool {
        delete(id: id)
        let secrets = headers.filter { HTTPHeaders.isSensitive($0.key) && !$0.value.isEmpty }
        guard !secrets.isEmpty else { return false }
        var query = itemQuery(account: id.uuidString)
        query[kSecValueData as String] = try JSONEncoder().encode(secrets)
        query[kSecAttrLabel as String] = "Osprey download sign-in"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return true
    }

    public func headers(id: UUID) -> [String: String] {
        var query = itemQuery(account: id.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let headers = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return headers
    }

    public func delete(id: UUID) {
        SecItemDelete(itemQuery(account: id.uuidString) as CFDictionary)
    }

    public func deleteAll(except keep: Set<UUID>) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            if let id = UUID(uuidString: account), keep.contains(id) { continue }
            SecItemDelete(itemQuery(account: account) as CFDictionary)
        }
    }

    /// True when this process may add, read and delete items under `service`. An unsigned test binary may be refused.
    public static func isAvailable(service: String) -> Bool {
        let probe = CredentialVault(service: service)
        let id = UUID()
        guard (try? probe.store(id: id, headers: ["Cookie": "probe=1"])) == true else { return false }
        let readBack = probe.headers(id: id) == ["Cookie": "probe=1"]
        probe.delete(id: id)
        return readBack
    }

    private func itemQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
