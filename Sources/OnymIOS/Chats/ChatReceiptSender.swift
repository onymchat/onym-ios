import CryptoKit
import Foundation
import OnymTransport

/// Seals + ships `ChatReceiptPayload`s back to a message's sender.
/// Injected into the dispatcher (delivered receipts on receive) and the
/// chat thread (read receipts on view). Best-effort: a failed seal or
/// send is swallowed — a missing receipt only costs a check mark, never
/// correctness. Returns whether the transport accepted the publish so
/// the dispatcher can latch `deliveredAckSent` only on success and
/// retry the receipt on the next inbox replay otherwise.
protocol ChatReceiptSending: Sendable {
    @discardableResult
    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async -> Bool
}

/// Default no-op so the dispatcher's many test constructions don't have
/// to thread a receipt sender they don't exercise (same posture as
/// `pendingInvites` / `groupStateRefresher`). Reports `false` — nothing
/// was sent, so nothing should be latched as acked.
struct NoopChatReceiptSender: ChatReceiptSending {
    @discardableResult
    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async -> Bool { false }
}

struct ChatReceiptSender: ChatReceiptSending {
    let identity: IdentityRepository
    let inboxTransport: any InboxTransport

    @discardableResult
    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async -> Bool {
        guard !messageIDs.isEmpty else { return false }
        guard let active = await identity.currentIdentity() else { return false }
        let myBlsHex = active.blsPublicKey.map { String(format: "%02x", $0) }.joined()
        let payload = ChatReceiptPayload(
            version: 1,
            groupID: groupID,
            senderBlsPubkeyHex: myBlsHex,
            kind: kind,
            messageIDs: messageIDs
        )
        guard let bytes = try? JSONEncoder().encode(payload),
              let sealed = try? await identity.sealInvitation(payload: bytes, to: recipientInboxKey)
        else { return false }
        let tag = TransportInboxID(rawValue: Self.inboxTag(from: recipientInboxKey))
        return (try? await inboxTransport.send(sealed, to: tag)) != nil
    }

    /// Same derivation as `SendMessageInteractor` / `IntroInboxPump`.
    static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The single symmetric read-receipt setting (default ON). Gates BOTH
/// sending read receipts and honoring inbound ones, so you only see
/// others' read status if you also share yours. Delivered receipts are
/// unconditional and not covered here.
enum ReadReceiptsPreference {
    /// Shared with the Settings `@AppStorage` toggle so both read/write
    /// the same key.
    static let storageKey = "app.onym.ios.chat.sendReadReceipts"

    static var isEnabled: Bool {
        get {
            // Absent key → default ON.
            UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}
