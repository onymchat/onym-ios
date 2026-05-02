import CryptoKit
import Foundation
import OnymSDK

/// Owns the on-device identity. All Keychain I/O and OnymSDK calls happen
/// here; views observe `snapshots` and never touch either.
///
/// ## Reactive surface
///
/// `snapshots` is an `AsyncStream<Identity?>`. Every subscriber immediately
/// receives the current value (possibly `nil` before bootstrap), then a
/// fresh value after every successful `bootstrap`, `generateNew`, `restore`,
/// or `wipe`. Subscribers consume via `for await snap in repo.snapshots`.
///
/// ## Threading
///
/// The actor's executor serialises all mutation. Keychain reads / writes,
/// PBKDF2, HKDF, and FFI calls into OnymSDK all run on the actor — never on
/// the main thread by construction. Views interact via `await` from a
/// `Task` (typically a SwiftUI `.task`).
actor IdentityRepository: InvitationEnvelopeDecrypting, InvitationEnvelopeSealing {
    static let shared = IdentityRepository()

    private let keychain: KeychainStore
    private var current: Identity?
    private var continuations: [UUID: AsyncStream<Identity?>.Continuation] = [:]

    init(keychain: KeychainStore = .default) {
        self.keychain = keychain
    }

    /// Load the persisted identity, or generate a fresh BIP39 one if none
    /// exists. Idempotent: a second call after success is a no-op that
    /// returns the same identity.
    @discardableResult
    func bootstrap() throws -> Identity {
        if let current { return current }
        if let snapshot = try keychain.load() {
            let identity = try Self.identity(from: snapshot)
            apply(identity)
            return identity
        }
        return try generateNewLocked()
    }

    /// Generate a fresh BIP39-backed identity, replacing any existing
    /// stored identity. The previous identity is unrecoverable after this
    /// call (no in-app backup is taken).
    @discardableResult
    func generateNew() throws -> Identity {
        try generateNewLocked()
    }

    /// Restore an identity from a 12- or 24-word BIP39 mnemonic, replacing
    /// any existing stored identity.
    @discardableResult
    func restore(mnemonic: String) throws -> Identity {
        guard Bip39.isValidMnemonic(mnemonic) else {
            throw IdentityError.invalidMnemonic
        }
        guard var entropy = Bip39.entropyFromMnemonic(mnemonic) else {
            throw IdentityError.invalidMnemonic
        }
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        let snapshot = Self.snapshot(fromEntropy: entropy)
        try keychain.save(snapshot)
        let identity = try Self.identity(from: snapshot)
        apply(identity)
        return identity
    }

    /// Delete the persisted identity. Subscribers receive a `nil` snapshot.
    func wipe() throws {
        try keychain.wipe()
        apply(nil)
    }

    /// The most recently observed identity, or `nil` if not bootstrapped or
    /// wiped. Reading this does not trigger a Keychain load.
    func currentIdentity() -> Identity? { current }

    /// Stream of identity snapshots — current value on subscribe, then one
    /// new value per successful mutation.
    nonisolated var snapshots: AsyncStream<Identity?> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Invitation decryption

    /// Decode an inbox-transport-delivered invitation envelope and open
    /// it with the X25519 private key derived from the persisted nostr
    /// secret. The private key is recomputed on every call (single
    /// HKDF) and discarded — secret material never escapes this actor.
    func decryptInvitation(envelopeBytes: Data) throws -> Data {
        let envelope: SealedEnvelope
        do {
            envelope = try JSONDecoder().decode(SealedEnvelope.self, from: envelopeBytes)
        } catch {
            throw InvitationDecryptError.malformedEnvelope
        }
        guard envelope.scheme == "x25519-aes-256-gcm-v1" else {
            throw InvitationDecryptError.unsupportedScheme(envelope.scheme)
        }
        guard let ephPubData = envelope.ephemeralPublicKey else {
            throw InvitationDecryptError.missingEphemeralKey
        }
        guard let nonceData = envelope.nonce, let tag = envelope.authenticationTag else {
            throw InvitationDecryptError.missingNonceOrTag
        }

        // M-5 / N-1: verify Ed25519 signature on the ephemeral pubkey if
        // present. Prevents a relay from substituting its own ephemeral
        // key (which would let it decrypt the invitation in flight).
        if let sigData = envelope.ephemeralKeySignature,
           let senderPubData = envelope.senderEd25519PublicKey {
            do {
                let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: senderPubData)
                guard verifyingKey.isValidSignature(sigData, for: ephPubData) else {
                    throw InvitationDecryptError.signatureVerificationFailed
                }
            } catch let error as InvitationDecryptError {
                throw error
            } catch {
                throw InvitationDecryptError.signatureVerificationFailed
            }
        }

        guard let snapshot = try keychain.load() else {
            throw InvitationDecryptError.identityNotLoaded
        }
        let privateKey = try Self.inboxKeyAgreementPrivateKey(fromNostrSecret: snapshot.nostrSecretKey)

        do {
            let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubData)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephPub)
            let key = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("sep-invitation-v1".utf8),
                sharedInfo: Data("aes-256-gcm".utf8),
                outputByteCount: 32
            )
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw InvitationDecryptError.decryptionFailed
        }
    }

    // MARK: - Invitation sealing

    /// Sender-side mirror of `decryptInvitation`. Generates a fresh
    /// per-envelope X25519 keypair, derives an AES-GCM key from the
    /// ECDH shared secret with the recipient's inbox pubkey, encrypts
    /// the payload, signs the ephemeral pubkey with the device's
    /// Ed25519 identity key (M-5), and returns the JSON-serialised
    /// `SealedEnvelope`. Secret material never escapes this actor —
    /// only the resulting bytes do.
    func sealInvitation(
        payload: Data,
        to recipientInboxPublicKey: Data
    ) async throws -> Data {
        let recipientPubkey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientPubkey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: recipientInboxPublicKey
            )
        } catch {
            throw InvitationSealError.invalidRecipientPublicKey
        }

        guard let snapshot = try keychain.load() else {
            throw InvitationSealError.identityNotLoaded
        }
        let signingKey = try Self.stellarSigningPrivateKey(fromNostrSecret: snapshot.nostrSecretKey)

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPubkey)
        } catch {
            throw InvitationSealError.encryptionFailed
        }
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("sep-invitation-v1".utf8),
            sharedInfo: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )

        let nonce = AES.GCM.Nonce()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(payload, using: key, nonce: nonce)
        } catch {
            throw InvitationSealError.encryptionFailed
        }

        let ephPubData = Data(ephemeral.publicKey.rawRepresentation)
        let ephSig: Data
        do {
            ephSig = try signingKey.signature(for: ephPubData)
        } catch {
            throw InvitationSealError.signingFailed
        }
        let senderPubData = Data(signingKey.publicKey.rawRepresentation)

        let envelope = SealedEnvelope(
            version: 1,
            scheme: "x25519-aes-256-gcm-v1",
            ephemeralPublicKey: ephPubData,
            ephemeralKeySignature: ephSig,
            senderEd25519PublicKey: senderPubData,
            nonce: Data(nonce),
            ciphertext: Data(sealed.ciphertext),
            authenticationTag: Data(sealed.tag)
        )

        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            throw InvitationSealError.encodingFailed
        }
    }

    // MARK: - Private

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<Identity?>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(current)
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func apply(_ identity: Identity?) {
        current = identity
        for continuation in continuations.values {
            continuation.yield(identity)
        }
    }

    private func generateNewLocked() throws -> Identity {
        let mnemonic = Bip39.generateMnemonic()
        guard var entropy = Bip39.entropyFromMnemonic(mnemonic) else {
            // unreachable: generateMnemonic always emits a valid mnemonic
            throw IdentityError.invalidMnemonic
        }
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        let snapshot = Self.snapshot(fromEntropy: entropy)
        try keychain.save(snapshot)
        let identity = try Self.identity(from: snapshot)
        apply(identity)
        return identity
    }

    private static func snapshot(fromEntropy entropy: Data) -> StoredSnapshot {
        let mnemonic = Bip39.mnemonicFromEntropy(entropy)
        var seed = Bip39.seedFromMnemonic(mnemonic)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return StoredSnapshot(
            entropy: entropy,
            nostrSecretKey: Bip39.deriveNostrKey(from: seed),
            blsSecretKey: Bip39.deriveBlsKey(from: seed)
        )
    }

    private static func identity(from snapshot: StoredSnapshot) throws -> Identity {
        guard snapshot.nostrSecretKey.count == 32 else {
            throw IdentityError.storedSnapshotInvalid(
                reason: "nostrSecretKey: expected 32 bytes, got \(snapshot.nostrSecretKey.count)"
            )
        }
        guard snapshot.blsSecretKey.count == 32 else {
            throw IdentityError.storedSnapshotInvalid(
                reason: "blsSecretKey: expected 32 bytes, got \(snapshot.blsSecretKey.count)"
            )
        }
        let nostrPub: Data
        let blsPub: Data
        do {
            nostrPub = try Common.nostrDerivePublicKey(secretKey: snapshot.nostrSecretKey)
            blsPub = try Common.publicKey(secretKey: snapshot.blsSecretKey)
        } catch {
            throw IdentityError.sdkFailure(String(describing: error))
        }
        let stellarPub = stellarPublicKey(fromNostrSecret: snapshot.nostrSecretKey)
        let inboxPub = inboxPublicKey(fromNostrSecret: snapshot.nostrSecretKey)
        let phrase = snapshot.entropy.map(Bip39.mnemonicFromEntropy)
        return Identity(
            nostrPublicKey: nostrPub,
            blsPublicKey: blsPub,
            stellarPublicKey: stellarPub,
            stellarAccountID: StellarStrKey.encodeAccountID(stellarPub),
            inboxPublicKey: inboxPub,
            inboxTag: inboxTag(from: inboxPub),
            recoveryPhrase: phrase
        )
    }

    /// HKDF-SHA256(nostrSecret, salt="chat.onym.ios", info="stellar-ed25519-v1", 32B).
    /// The 32-byte output is used directly as the Ed25519 seed.
    /// **MUST** match `KeyManager.deriveStellarKey` in stellar-mls — a recovery
    /// phrase generated there must produce the same `G...` account ID here.
    private static func stellarPublicKey(fromNostrSecret nostrSecret: Data) -> Data {
        let privateKey = (try? stellarSigningPrivateKey(fromNostrSecret: nostrSecret))!
        return Data(privateKey.publicKey.rawRepresentation)
    }

    /// Sibling of `stellarPublicKey` that returns the Ed25519
    /// *private* key. Used by `sealInvitation` for the M-5 attestation
    /// signature on per-envelope ephemeral pubkeys. Never leaves this
    /// actor.
    private static func stellarSigningPrivateKey(
        fromNostrSecret nostrSecret: Data
    ) throws -> Curve25519.Signing.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: nostrSecret),
            salt: Data("chat.onym.ios".utf8),
            info: Data("stellar-ed25519-v1".utf8),
            outputByteCount: 32
        )
        let seed = derived.withUnsafeBytes { Data($0) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// HKDF-SHA256(nostrSecret, salt="chat.onym.ios", info="x25519-key-agreement-v1", 32B).
    /// **MUST** match `KeyManager.deriveKeyAgreementKey` in stellar-mls.
    private static func inboxPublicKey(fromNostrSecret nostrSecret: Data) -> Data {
        let privateKey = (try? inboxKeyAgreementPrivateKey(fromNostrSecret: nostrSecret))!
        return Data(privateKey.publicKey.rawRepresentation)
    }

    /// Sibling of `inboxPublicKey` that returns the X25519 *private* key
    /// instead of just the public half. Used internally by
    /// `decryptInvitation`. The private key never leaves this actor.
    private static func inboxKeyAgreementPrivateKey(
        fromNostrSecret nostrSecret: Data
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: nostrSecret),
            salt: Data("chat.onym.ios".utf8),
            info: Data("x25519-key-agreement-v1".utf8),
            outputByteCount: 32
        )
        let seed = derived.withUnsafeBytes { Data($0) }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
    }

    /// First 8 bytes of `SHA-256("sep-inbox-v1" || inboxPublicKey)`, hex-encoded
    /// (16 chars). **MUST** match `GroupCrypto.hiddenInboxTag` in stellar-mls.
    private static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let hash = hasher.finalize()
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
