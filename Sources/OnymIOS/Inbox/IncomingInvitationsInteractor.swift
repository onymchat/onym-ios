import Foundation

/// Stateless pump: subscribe to an `InboxTransport`, persist every
/// inbound message as a pending `IncomingInvitation` via the
/// repository. Decryption / parsing of the payload happens above this
/// layer (it needs the X25519 key from `IdentityRepository`); the pump
/// stores the opaque ciphertext as-is.
///
/// "Stateless" means the interactor owns no domain state itself — it
/// only ever holds the seam references it needs. The state machine
/// lives in the repository (which owns the persistence seam).
struct IncomingInvitationsInteractor: Sendable {
    let inboxTransport: any InboxTransport
    let repository: IncomingInvitationsRepository

    /// Run until cancelled. Each `InboundInbox` becomes one
    /// `recordIncoming` call on the repository; the repository's
    /// idempotent save handles duplicates from redundant relays.
    /// Caller owns the `Task` and is responsible for cancellation.
    func run(inbox: TransportInboxID) async {
        for await message in inboxTransport.subscribe(inbox: inbox) {
            if Task.isCancelled { break }
            await repository.recordIncoming(
                id: message.messageID,
                payload: message.payload,
                receivedAt: message.receivedAt
            )
        }
    }
}
