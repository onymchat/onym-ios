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
    func delete(id: String) async
    /// Drop the rows whose group now exists locally. Matched on hex so
    /// the caller can pass what `GroupRepository` gave it without
    /// decrypting a single row.
    func deleteForGroups(hexes: Set<String>) async
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

    public func delete(id: String) async {
        rows.removeAll { $0.id == id }
    }

    public func deleteForGroups(hexes: Set<String>) async {
        guard !hexes.isEmpty else { return }
        rows.removeAll { hexes.contains($0.groupIDHex) }
    }

    public func deleteOwner(_ ownerIDString: String) async {
        rows.removeAll { $0.ownerIdentityID.rawValue.uuidString == ownerIDString }
    }

    public func list() async -> [PendingChat] {
        rows.sorted { $0.receivedAt > $1.receivedAt }
    }
}
