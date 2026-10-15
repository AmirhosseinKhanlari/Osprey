import Foundation

/// The saved list's rules for download events:
/// - A private download never reaches the list or the Keychain.
/// - Adding writes the record (within the library's 1 s window) and stores any credentials.
/// - A pause, failure or completion is flushed when the caller asks (`flush`); completion also deletes the credentials.
/// - Removing (Remove, Remove from list, Clear completed, Cancel) deletes the record and the credentials, and flushes.
///   A removed id stays removed: an `added` or `changed` that arrives later (a refresh that was awaiting the task when
///   the user removed it) is ignored, so the download never comes back. Retry gives the new download a new id.
///
/// Every Keychain call happens here, on this actor, never on the main thread.
public actor LibraryRecorder {
    private let library: DownloadLibrary
    private let vault: any CredentialStoring
    private var removedIDs: Set<UUID> = []
    /// Downloads whose credentials this session stored: launch pruning keeps them.
    private var storedThisSession: Set<UUID> = []

    public init(library: DownloadLibrary, vault: any CredentialStoring) {
        self.library = library
        self.vault = vault
    }

    /// Returns whether credentials were stored.
    @discardableResult
    public func added(_ record: DownloadRecord, credentials: [String: String], isPrivate: Bool) async -> Bool {
        guard !isPrivate, !removedIDs.contains(record.id) else { return false }
        var record = record
        record.hasStoredCredentials = (try? vault.store(id: record.id, headers: credentials)) ?? false
        if record.hasStoredCredentials { storedThisSession.insert(record.id) }
        await library.update(record)
        return record.hasStoredCredentials
    }

    public func changed(_ record: DownloadRecord, isPrivate: Bool, flush: Bool) async {
        guard !isPrivate, !removedIDs.contains(record.id) else { return }
        await library.update(record)
        if record.state == .completed { vault.delete(id: record.id) }
        if flush { await library.flush() }
    }

    public func removed(id: UUID, isPrivate: Bool) async {
        guard !isPrivate else { return }
        removedIDs.insert(id)
        await library.remove(id: id)
        vault.delete(id: id)
        await library.flush()
    }

    /// The stored sign-in headers of download `id`, or an empty dictionary.
    public func credentials(id: UUID) -> [String: String] {
        vault.headers(id: id)
    }

    /// At launch: deletes the Keychain items of downloads that are gone (a crash's orphans), keeping `keep` and any
    /// download this session already stored credentials for (a capture that arrived before this ran).
    public func pruneCredentials(keeping keep: Set<UUID>) {
        vault.deleteAll(except: keep.union(storedThisSession))
    }
}
