import Foundation

/// Lifecycle of a received invitation. The interactor only writes
/// `pending`; later flows transition to `accepted` (joined the group) or
/// `declined` (user dismissed).
enum IncomingInvitationStatus: String, Sendable, CaseIterable {
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
struct IncomingInvitationRecord: Sendable, Equatable {
    let id: String
    let payload: Data
    let receivedAt: Date
    let status: IncomingInvitationStatus
}

/// Persistence seam for incoming invitations. Async surface so a
/// concrete impl can serialise writes on its own queue without forcing
/// callers onto a specific actor.
protocol InvitationStore: Sendable {
    func list() async -> [IncomingInvitationRecord]

    /// Idempotent on `id`: a second save of the same invitation id is a
    /// no-op (preserves the original `receivedAt` + `status`). Returns
    /// `true` when a new row was inserted, `false` on dedup hit.
    @discardableResult
    func save(_ record: IncomingInvitationRecord) async -> Bool

    func updateStatus(id: String, status: IncomingInvitationStatus) async
    func delete(id: String) async
}
