import CryptoKit
import Foundation

/// Sender-side pump for intro inbox subscriptions. Mirrors
/// `InboxFanoutInteractor` but drops inbounds into
/// `IntroRequestStore` instead of the identity-inbox sink.
///
/// **Why a parallel interactor instead of one shared seam**: the
/// two flows are likely to diverge — intro requests are interactive
/// (sender taps Approve), invitations are autonomic (joiner sees
/// the chat appear). Shared abstraction would leak through either
/// a generic-type parameter or a sink interface that adds
/// indirection without saving meaningful code.
///
/// Subscription set is rebuilt by reconciliation: each emission
/// from the entries stream cancels Tasks for entries that
/// disappeared (or whose pubkey rotated), spawns Tasks for new
/// entries, no-ops the rest. Each per-entry Task captures the
/// `IntroKeyEntry` so inbounds can be tagged with the matching
/// introPub directly — no `tag → pub` reverse-lookup map needed.
struct IntroInboxPump: Sendable {
    let inboxTransport: any InboxTransport
    let store: any IntroRequestStore
    /// Maps an intro pubkey → its Nostr inbox tag. Production wires
    /// to `Self.inboxTag(from:)` (the same
    /// `SHA-256("sep-inbox-v1" || pub)[..8]` derivation identity
    /// inbox tags use); tests pass an identity-equality stub.
    let inboxTagFor: @Sendable (Data) -> TransportInboxID

    init(
        inboxTransport: any InboxTransport,
        store: any IntroRequestStore,
        inboxTagFor: (@Sendable (Data) -> TransportInboxID)? = nil
    ) {
        self.inboxTransport = inboxTransport
        self.store = store
        self.inboxTagFor = inboxTagFor ?? { pub in
            TransportInboxID(rawValue: Self.inboxTag(from: pub))
        }
    }

    /// Run until cancelled. Each entries-stream emission re-balances
    /// the live subscription set wholesale.
    func run(entries: AsyncStream<[IntroKeyEntry]>) async {
        let subs = ActiveIntroSubscriptions(
            inboxTransport: inboxTransport,
            store: store
        )
        for await snapshot in entries {
            if Task.isCancelled { break }
            await subs.apply(snapshot, tagFor: inboxTagFor)
        }
        await subs.applyEmpty()
    }

    /// Mirror of `IdentityRepository.inboxTag(from:)` /
    /// `InboxFanoutInteractor.inboxTag(from:)`. Pure function of
    /// the pubkey; safe to recompute.
    static func inboxTag(from publicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: publicKey)
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Subscription bookkeeping actor

/// Owns the live per-entry subscription Tasks. `apply` reconciles
/// the desired set against the live set: cancels Tasks for entries
/// that disappeared, spawns Tasks for new ones, no-ops the rest.
private actor ActiveIntroSubscriptions {
    private let inboxTransport: any InboxTransport
    private let store: any IntroRequestStore
    /// Keyed by introPub. The captured tag travels with each Task
    /// so cancellation can also `unsubscribe` the right inbox.
    private var live: [Data: (tag: TransportInboxID, task: Task<Void, Never>)] = [:]

    init(inboxTransport: any InboxTransport, store: any IntroRequestStore) {
        self.inboxTransport = inboxTransport
        self.store = store
    }

    func apply(
        _ wanted: [IntroKeyEntry],
        tagFor: @Sendable (Data) -> TransportInboxID
    ) async {
        let wantedKeys = Set(wanted.map { $0.introPublicKey })
        // Cancel anything that disappeared.
        for (pub, current) in live where !wantedKeys.contains(pub) {
            current.task.cancel()
            await inboxTransport.unsubscribe(inbox: current.tag)
            live.removeValue(forKey: pub)
        }
        // Spawn anything new.
        for entry in wanted where live[entry.introPublicKey] == nil {
            let tag = tagFor(entry.introPublicKey)
            let stream = inboxTransport.subscribe(inbox: tag)
            let pubCapture = entry.introPublicKey
            let task = Task { [store] in
                for await message in stream {
                    if Task.isCancelled { break }
                    await store.record(IntroRequest(
                        id: message.messageID,
                        targetIntroPublicKey: pubCapture,
                        payload: message.payload,
                        receivedAt: message.receivedAt
                    ))
                }
            }
            live[entry.introPublicKey] = (tag, task)
        }
    }

    func applyEmpty() async {
        for (_, current) in live {
            current.task.cancel()
            await inboxTransport.unsubscribe(inbox: current.tag)
        }
        live.removeAll()
    }
}
