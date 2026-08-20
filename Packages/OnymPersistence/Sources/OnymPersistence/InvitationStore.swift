import Foundation
import OnymIdentity

/// Lifecycle of a received invitation. The interactor only writes
/// `pending`; later flows transition to `accepted` (joined the group) or
/// `declined` (user dismissed).
public enum IncomingInvitationStatus: String, Sendable, CaseIterable {
    case pending
    case accepted
    case declined
}

/// Domain shape of one received invitation. The `payload` is the opaque
/// inbox-transport bytes — already encrypted for us by the sender.
/// Decryption + parsing happens above this layer (it needs the X25519
/// key from `IdentityRepository`); the persistence seam treats the
/// payload as opaque ciphertext that gets a second AES-GCM wrapper at
/// rest.
public struct IncomingInvitationRecord: Sendable, Equatable {
    public let id: String
    /// The identity this envelope was delivered to. The fan-out
    /// transport stamps this from the inbox tag the message arrived
    /// on, so `IdentityRepository.decryptInvitation(asIdentity:)`
    /// always uses the right per-identity X25519 key — even when the
    /// receiving identity isn't the currently-selected one.
    public let ownerIdentityID: IdentityID
    public let payload: Data
    public let receivedAt: Date
    public let status: IncomingInvitationStatus

    public init(
        id: String,
        ownerIdentityID: IdentityID,
        payload: Data,
        receivedAt: Date,
        status: IncomingInvitationStatus
    ) {
        self.id = id
        self.ownerIdentityID = ownerIdentityID
        self.payload = payload
        self.receivedAt = receivedAt
        self.status = status
    }
}

/// Result of `InvitationStore.save`. Same three-way shape as
/// `MessageInsertOutcome` and `GroupInsertOutcome`, and a separate type
/// from both for the reason spelled out on `GroupInsertOutcome`: the
/// middle case here is not theirs. Saving over an existing invitation
/// does not overwrite it — the store declines the write so the original
/// `receivedAt` and `status` survive, which is the whole point of the
/// dedup. Calling that `.updated` would say the opposite of what
/// happened, so it is `.duplicate`.
///
/// `.duplicate` and `.failed` used to be the same `false`, which read
/// as "not new" to anyone asking and as "not stored" to anyone
/// counting. They are as far apart as two answers get: one means the
/// row is on the device and has been since the first time, the other
/// means it is not on the device at all.
public enum InvitationSaveOutcome: Sendable, Equatable {
    /// New row persisted.
    case saved
    /// A row with this `id` already existed; nothing was written and
    /// the original row is untouched.
    case duplicate
    /// Nothing was persisted — the payload could not be encrypted.
    case failed
}

/// Persistence seam for incoming invitations. Async surface so a
/// concrete impl can serialise writes on its own queue without forcing
/// callers onto a specific actor.
public protocol InvitationStore: Sendable {
    func list() async -> [IncomingInvitationRecord]

    /// Idempotent on `id`: a second save of the same invitation id is a
    /// no-op (preserves the original `receivedAt` + `status`).
    ///
    /// Answered `Bool` until the backup sink needed to tell a dedup hit
    /// from a payload that would not encrypt, and found both spelled
    /// `false`. It had to read `list()` first and infer which one it
    /// had; the store knew all along.
    @discardableResult
    func save(_ record: IncomingInvitationRecord) async -> InvitationSaveOutcome

    func updateStatus(id: String, status: IncomingInvitationStatus) async
    func delete(id: String) async

    /// Drop every invitation row whose `ownerIdentityIDString` matches.
    /// Used by `IncomingInvitationsRepository.removeForOwner` in
    /// response to `IdentityRepository.identityRemoved` — mirrors
    /// `GroupStore.deleteOwner`.
    func deleteOwner(_ ownerIDString: String) async
}
