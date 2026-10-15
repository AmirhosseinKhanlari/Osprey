import Foundation
import OspreyEngine
@testable import OspreyLibrary

/// The vault's rules in memory, for tests: only non-empty Cookie / Authorization values are kept.
final class FakeVault: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: [String: String]] = [:]
    private var _calls = 0

    /// Every call, of any kind (a private download must cause none).
    var calls: Int { lock.withLock { _calls } }
    var storedIDs: Set<UUID> { lock.withLock { Set(items.keys) } }

    @discardableResult
    func store(id: UUID, headers: [String: String]) throws -> Bool {
        lock.withLock {
            _calls += 1
            let secrets = headers.filter { HTTPHeaders.isSensitive($0.key) && !$0.value.isEmpty }
            items[id] = secrets.isEmpty ? nil : secrets
            return !secrets.isEmpty
        }
    }

    func headers(id: UUID) -> [String: String] {
        lock.withLock {
            _calls += 1
            return items[id] ?? [:]
        }
    }

    func delete(id: UUID) {
        lock.withLock {
            _calls += 1
            items[id] = nil
        }
    }

    func deleteAll(except keep: Set<UUID>) {
        lock.withLock {
            _calls += 1
            items = items.filter { keep.contains($0.key) }
        }
    }
}
