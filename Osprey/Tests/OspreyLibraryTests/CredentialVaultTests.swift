import Foundation
import Testing
@testable import OspreyLibrary

/// The real Keychain, under a service of this run's own. An unsigned `swift test` binary may be refused; then the
/// Keychain tests are skipped and only the fake is checked.
private enum KeychainSupport {
    static let service = "com.akhanlari.osprey.download-credentials.tests.\(UUID().uuidString)"
    static let works = CredentialVault.isAvailable(service: service)
}

/// What every vault must do: keep only the secrets, replace on a second store, and delete by id or all-but.
private func checkContract(_ vault: some CredentialStoring) throws {
    let first = UUID(), second = UUID(), third = UUID()
    defer { vault.deleteAll(except: []) }
    #expect(try vault.store(id: first, headers: ["Cookie": "SID=1", "Authorization": "Bearer t", "User-Agent": "UA"]))
    #expect(vault.headers(id: first) == ["Cookie": "SID=1", "Authorization": "Bearer t"])
    #expect(try vault.store(id: second, headers: ["User-Agent": "UA", "Cookie": ""]) == false)   // nothing secret: nothing kept
    #expect(vault.headers(id: second).isEmpty)
    #expect(try vault.store(id: second, headers: ["cookie": "b=2"]))
    #expect(try vault.store(id: third, headers: ["Cookie": "c=3"]))
    #expect(try vault.store(id: third, headers: ["Cookie": "c=4"]))                       // a second store replaces
    #expect(vault.headers(id: third) == ["Cookie": "c=4"])
    vault.delete(id: first)
    #expect(vault.headers(id: first).isEmpty)
    vault.deleteAll(except: [third])
    #expect(vault.headers(id: second).isEmpty)
    #expect(vault.headers(id: third) == ["Cookie": "c=4"])
}

@Suite struct CredentialVaultTests {
    @Test func theFakeFollowsTheContract() throws {
        try checkContract(FakeVault())
    }

    @Test(.enabled(if: KeychainSupport.works, "the Keychain refuses this unsigned test binary"))
    func theKeychainVaultFollowsTheContract() throws {
        // Each Keychain test has its own service: Swift Testing runs them in parallel, and `deleteAll` empties one.
        try checkContract(CredentialVault(service: KeychainSupport.service + ".contract"))
    }

    @Test(.enabled(if: KeychainSupport.works, "the Keychain refuses this unsigned test binary"))
    func deleteAllLeavesOtherServicesAlone() throws {
        let mine = CredentialVault(service: KeychainSupport.service + ".mine")
        let other = CredentialVault(service: KeychainSupport.service + ".other")
        let id = UUID()
        defer { other.deleteAll(except: []); mine.deleteAll(except: []) }
        #expect(try mine.store(id: id, headers: ["Cookie": "a=1"]))
        #expect(try other.store(id: id, headers: ["Cookie": "b=2"]))
        mine.deleteAll(except: [])
        #expect(mine.headers(id: id).isEmpty)
        #expect(other.headers(id: id) == ["Cookie": "b=2"])
    }
}
