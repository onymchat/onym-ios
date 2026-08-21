import Foundation
import OnymIdentity

/// Persistence seam for pending chats. Mirrors `GroupStore`: the store
/// holds rows for *every* identity on the device and knows nothing about
/// which one is selected — the per-identity filtering and the snapshot
/// stream live one layer up, in `PendingChatRepository`.
public protocol PendingChatStore: Sendable {
    /// Idempotent on `PendingChat.id`. An existing row is returned
    /// untouched (`.alreadyPresent`), never overwritten — see
    /// `PendingChatRecording.record`.
    @discardableResult
    func insert(_ chat: PendingChat) async -> PendingChatWriteOutcome
    /// Replace the status of an existing row. No-op when the row is
    /// gone, which is the ordinary race: the group can materialize
    /// while a join request is still in flight.
    func setStatus(id: String, status: PendingChat.Status) async
    /// Take the reply channel and the descriptive fields from a newer
    /// offer for a row that already exists, leaving its status alone.
    ///
    /// A re-invite mints a *fresh* intro key and "Generate new link"
    /// revokes the old one (`IntroKeyStore.revoke`), so a row that kept
    /// the first key would seal its request to a dead address — the
    /// transport reports success, the founder never hears it, and the
    /// row waits forever with nothing to show for it. Newer offer wins,
    /// because the newer key is the only one that can be answered.
    func refreshOffer(
        id: String,
        introPublicKey: Data,
        groupName: String?,
        inviterAlias: String,
        invitationMessage: String?
    ) async
    func delete(id: String) async
    /// Drop rows by id — `<group id hex>:<owner uuid>`, the same key
    /// `insert` dedupes on. Ids rather than group hexes because two
    /// identities on one device can each be waiting on the same group,
    /// and matching on the group alone would delete the other one's row
    /// when this one got in.
    func deleteForIDs(_ ids: Set<String>) async
    func deleteOwner(_ ownerIDString: String) async
    /// Every row on the device, newest first.
    func list() async -> [PendingChat]
}

/// Process-lifetime `PendingChatStore` for tests and for a device whose
/// on-disk store could not be opened. Losing these rows on relaunch is
/// exactly the failure the SwiftData store exists to prevent, so this is
/// a fallback, not a default.
public actor InMemoryPendingChatStore: PendingChatStore {
    private var rows: [PendingChat] = []

    public init() {}

    @discardableResult
    public func insert(_ chat: PendingChat) async -> PendingChatWriteOutcome {
        guard !rows.contains(where: { $0.id == chat.id }) else { return .alreadyPresent }
        rows.append(chat)
        return .inserted
    }

    public func setStatus(id: String, status: PendingChat.Status) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = status
    }

    public func refreshOffer(
        id: String,
        introPublicKey: Data,
        groupName: String?,
        inviterAlias: String,
        invitationMessage: String?
    ) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let existing = rows[index]
        rows[index] = PendingChat(
            groupID: existing.groupID,
            ownerIdentityID: existing.ownerIdentityID,
            introPublicKey: introPublicKey,
            groupName: groupName,
            inviterAlias: inviterAlias,
            invitationMessage: invitationMessage,
            receivedAt: existing.receivedAt,
            status: existing.status
        )
    }

    public func delete(id: String) async {
        rows.removeAll { $0.id == id }
    }

    public func deleteForIDs(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        rows.removeAll { ids.contains($0.id) }
    }

    public func deleteOwner(_ ownerIDString: String) async {
        rows.removeAll { $0.ownerIdentityID.rawValue.uuidString == ownerIDString }
    }

    public func list() async -> [PendingChat] {
        rows.sorted { $0.receivedAt > $1.receivedAt }
    }
}
