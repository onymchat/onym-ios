import CryptoKit
import Foundation

/// Seals + ships `ChatReceiptPayload`s back to a message's sender.
/// Injected into the dispatcher (delivered receipts on receive) and the
/// chat thread (read receipts on view). Best-effort: a failed seal or
/// send is swallowed — a missing receipt only costs a check mark, never
/// correctness.
protocol ChatReceiptSending: Sendable {
    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async
}

/// Default no-op so the dispatcher's many test constructions don't have
/// to thread a receipt sender they don't exercise (same posture as
/// `pendingInvites` / `groupStateRefresher`).
struct NoopChatReceiptSender: ChatReceiptSending {
    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async {}
}

struct ChatReceiptSender: ChatReceiptSending {
    let identity: IdentityRepository
    let inboxTransport: any InboxTransport

    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async {
        guard !messageIDs.isEmpty else { return }
        guard let active = await identity.currentIdentity() else { return }
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
        else { return }
        let tag = TransportInboxID(rawValue: Self.inboxTag(from: recipientInboxKey))
        _ = try? await inboxTransport.send(sealed, to: tag)
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
