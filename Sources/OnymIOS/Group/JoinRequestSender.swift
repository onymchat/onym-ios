import Foundation

/// Joiner-side: tap-the-deeplink → ship a sealed `JoinRequestPayload`
/// to the inviter's intro inbox.
///
/// Flow:
///  1. Build the payload (joiner's inbox pubkey + display label +
///     group id echo).
///  2. Seal the payload to `IntroCapability.introPublicKey` using
///     the existing `IdentityRepository.sealInvitation` (X25519
///     ECDH against intro_pub + AES-GCM + Ed25519 signature with
///     the joiner's long-term key).
///  3. POST the sealed bytes to the Nostr inbox tag derived from
///     intro_pub (same `sep-inbox-v1` derivation the identity inbox
///     uses).
///  4. Surface success/failure to the JoinScreen UI (PR-7).
actor JoinRequestSender {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport

    init(identity: IdentityRepository, inboxTransport: any InboxTransport) {
        self.identity = identity
        self.inboxTransport = inboxTransport
    }

    enum Outcome: Equatable, Sendable {
        case sent
        case noIdentityLoaded
        case transportFailed(String)
    }

    /// - Parameters:
    ///   - capability: decoded from the deeplink's `?c=…` payload.
    ///   - joinerDisplayLabel: surfaced in the inviter's approval
    ///     prompt. Joiner-controlled untrusted text — keep short
    ///     (Nostr relays typically cap event size at ~64KB and we
    ///     don't want to bloat the request envelope).
    func send(
        capability: IntroCapability,
        joinerDisplayLabel: String
    ) async -> Outcome {
        guard let active = await identity.currentIdentity() else {
            return .noIdentityLoaded
        }
        let payload: JoinRequestPayload
        do {
            payload = try JoinRequestPayload(
                joinerInboxPublicKey: active.inboxPublicKey,
                joinerBlsPublicKey: active.blsPublicKey,
                joinerDisplayLabel: joinerDisplayLabel,
                groupId: capability.groupId
            )
        } catch {
            return .transportFailed("payload: \(error)")
        }
        let payloadBytes: Data
        do {
            payloadBytes = try JSONEncoder().encode(payload)
        } catch {
            return .transportFailed("encode: \(error)")
        }
        let sealed: Data
        do {
            sealed = try await identity.sealInvitation(
                payload: payloadBytes,
                to: capability.introPublicKey
            )
        } catch {
            return .transportFailed("seal: \(error)")
        }
        let tag = TransportInboxID(rawValue: IntroInboxPump.inboxTag(from: capability.introPublicKey))
        let receipt: PublishReceipt
        do {
            receipt = try await inboxTransport.send(sealed, to: tag)
        } catch {
            return .transportFailed("send: \(error)")
        }
        guard receipt.acceptedBy >= 1 else {
            return .transportFailed("no relay accepted the request")
        }
        return .sent
    }
}
