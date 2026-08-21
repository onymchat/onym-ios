import Foundation
import OnymTransport
import OnymIdentity

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
///  4. Report the outcome to the caller, which records it on the
///     pending chat row — the screen that used to ask for this is gone.
public actor JoinRequestSender {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport

    public init(identity: IdentityRepository, inboxTransport: any InboxTransport) {
        self.identity = identity
        self.inboxTransport = inboxTransport
    }

    public enum Outcome: Equatable, Sendable {
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
    ///   - agreedRules: the rules text the joiner was shown and
    ///     accepted, or nil when the invitation carried none.
    ///
    ///     Passed in rather than read off `capability`, because the
    ///     signature has to cover what a person actually saw. The two
    ///     are the same for a link, but an invitation pushed to this
    ///     device carries its rules on the stored offer instead, and a
    ///     sender that reached for the capability's copy would sign
    ///     text that was never on screen in that case.
    public func send(
        capability: IntroCapability,
        joinerDisplayLabel: String,
        agreedRules: String? = nil
    ) async -> Outcome {
        guard let active = await identity.currentIdentity() else {
            return .noIdentityLoaded
        }
        // Compute leaf_hash = Poseidon(joiner_bls_secret) so the
        // admin can extend the Merkle tree at approve time without
        // ever seeing the joiner's BLS secret.
        let blsSecret: Data
        do {
            // onym:allow-secret-read
            blsSecret = try await identity.blsSecretKey()
        } catch {
            return .noIdentityLoaded
        }
        let leafHash: Data
        do {
            leafHash = try GroupCommitmentBuilder.computeLeafHash(secretKey: blsSecret)
        } catch {
            return .transportFailed("leaf_hash: \(error)")
        }
        // The agreement, when there is one to make. Signed with the
        // same long-term key the request already announces as
        // `joinerSendingPublicKey`, so every member who is later told
        // about this joiner can check it — not just the founder who
        // admitted them.
        var rulesHash: Data?
        var rulesSignature: Data?
        if let rules = GroupRules.normalized(agreedRules) {
            let hash = GroupRules.hash(rules)
            do {
                rulesSignature = try await identity.signWithStellarKey(
                    GroupRules.statement(
                        groupID: capability.groupId,
                        rulesHash: hash,
                        joinerSendingPublicKey: active.stellarPublicKey
                    )
                )
                rulesHash = hash
            } catch {
                // Nothing is sent unsigned behind the person's back:
                // they were shown rules and told that Send agrees to
                // them, and a request that arrives without the
                // signature reads to the founder as someone who
                // declined to agree.
                return .transportFailed("rules signature: \(error)")
            }
        }
        let payload: JoinRequestPayload
        do {
            payload = try JoinRequestPayload(
                joinerInboxPublicKey: active.inboxPublicKey,
                joinerBlsPublicKey: active.blsPublicKey,
                joinerLeafHash: leafHash,
                joinerSendingPublicKey: active.stellarPublicKey,
                joinerDisplayLabel: joinerDisplayLabel,
                groupId: capability.groupId,
                rulesHash: rulesHash,
                rulesSignature: rulesSignature
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
