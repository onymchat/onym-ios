import CryptoKit
import Foundation
import OnymSDK

/// Owns every on-device identity. All Keychain I/O and OnymSDK calls
/// happen here; views observe `identitiesStream` + `currentIdentityID`
/// + `snapshots` and never touch secret material directly.
///
/// ## Reactive surface
///
/// - `identitiesStream` — every persisted identity as `IdentitySummary`.
///   Re-broadcasts on every add/remove.
/// - `currentIdentityID` — the currently-selected identity ID, or nil
///   when none exist. Re-broadcasts on every `select`, `add` (when it
///   becomes the first), or `remove` (when the removed one was current).
/// - `snapshots` — the current identity (or nil), back-compat for
///   callers that just want "the active identity".
/// - `identityRemoved` — fires when an identity is removed; subscribers
///   (PR-3 `GroupRepository`) wipe identity-scoped state.
///
/// ## Threading
///
/// Single actor — every mutation is serialised on its executor. Keychain
/// reads/writes, PBKDF2, HKDF, and FFI calls into OnymSDK all run here.
/// Views interact via `await` from a `Task` (typically a SwiftUI `.task`).
actor IdentityRepository: InvitationEnvelopeDecrypting, InvitationEnvelopeSealing, IdentitiesProviding {
    static let shared = IdentityRepository()

    private let keychain: IdentityKeychainStore
    private let selectionStore: SelectedIdentityStore

    /// In-memory cache of every identity loaded from the keychain.
    /// Repopulated lazily on first access via `ensureLoaded()`.
    private var cache: [IdentityID: Identity] = [:]
    private var names: [IdentityID: String] = [:]
    private var orderedIDs: [IdentityID] = []
    private var currentID: IdentityID?
    private var loaded = false

    private var snapshotContinuations: [UUID: AsyncStream<Identity?>.Continuation] = [:]
    private var identitiesContinuations: [UUID: AsyncStream<[IdentitySummary]>.Continuation] = [:]
    private var currentIDContinuations: [UUID: AsyncStream<IdentityID?>.Continuation] = [:]
    private var removalContinuations: [UUID: AsyncStream<IdentityID>.Continuation] = [:]

    init(
        keychain: IdentityKeychainStore = IdentityKeychainStore(),
        selectionStore: SelectedIdentityStore = .userDefaults
    ) {
        self.keychain = keychain
        self.selectionStore = selectionStore
    }

    // MARK: - Bootstrap / lifecycle

    /// Ensure at least one identity exists. If the keychain is empty,
    /// generates a default-named one. Returns the currently-selected
    /// identity (post-bootstrap there's always one selected).
    @discardableResult
    func bootstrap() throws -> Identity {
        try ensureLoaded()
        if cache.isEmpty {
            let id = try addLocked(name: nil, mnemonic: nil)
            currentID = id
            persistSelection()
            broadcast()
        } else if currentID == nil {
            currentID = orderedIDs.first
            persistSelection()
            broadcast()
        }
        guard let currentID, let identity = cache[currentID] else {
            throw IdentityError.identityNotLoaded
        }
        return identity
    }

    /// Add a new identity. `name` defaults to "Identity N" where N is
    /// the next free slot; `mnemonic` either restores from a known
    /// phrase or generates a fresh one when nil. The new identity
    /// becomes current iff there was no current identity before.
    @discardableResult
    func add(name: String? = nil, mnemonic: String? = nil) throws -> IdentityID {
        try ensureLoaded()
        let id = try addLocked(name: name, mnemonic: mnemonic)
        if currentID == nil {
            currentID = id
            persistSelection()
        }
        broadcast()
        return id
    }

    /// Switch the currently-selected identity. Calls with an unknown
    /// `id` are no-ops (defensive — UI should never present an ID
    /// that isn't in the picker).
    func select(_ id: IdentityID) throws {
        try ensureLoaded()
        guard cache[id] != nil else { return }
        guard currentID != id else { return }
        currentID = id
        persistSelection()
        broadcast()
    }

    /// Remove the identity. Wipes its keychain item, drops it from the
    /// cache, picks a new current (next in order, or nil if it was the
    /// last). Subscribers of `identityRemoved` get notified so they
    /// can wipe identity-scoped state (chats, messages — PR-3).
    func remove(_ id: IdentityID) throws {
        try ensureLoaded()
        guard cache[id] != nil else { return }
        try keychain.wipe(id)
        cache.removeValue(forKey: id)
        names.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        if currentID == id {
            currentID = orderedIDs.first
            persistSelection()
        }
        for cont in removalContinuations.values { cont.yield(id) }
        broadcast()
    }

    /// Rename `id` to `newName`. Trims; blank input is a silent no-op
    /// (matches the iOS prototype's `name || i.name` "blank input keeps
    /// old name" behaviour) and unchanged values skip the disk write.
    ///
    /// Callable on any identity, active or inactive. Refreshes the
    /// `identitiesStream` summary list so listeners see the new name;
    /// the active `snapshots` stream isn't touched because `Identity`
    /// doesn't carry the display name (only `IdentitySummary` does).
    ///
    /// - Throws: `IdentityError.identityNotLoaded` if `id` doesn't exist
    ///   on this device.
    func rename(_ id: IdentityID, newName: String) throws {
        try ensureLoaded()
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        guard var snapshot = try keychain.read(id) else {
            throw IdentityError.identityNotLoaded
        }
        if snapshot.name == trimmed { return }
        snapshot.name = trimmed
        try keychain.write(id, snapshot)
        names[id] = trimmed
        broadcast()
    }

    /// Restore an identity from a 12- or 24-word BIP39 mnemonic. With
    /// the no-backcompat licence this wipes every existing identity
    /// first — preserves the legacy single-slot `restore` semantic so
    /// existing tests + the recovery-phrase backup flow keep working.
    @discardableResult
    func restore(mnemonic: String) throws -> Identity {
        guard Bip39.isValidMnemonic(mnemonic) else {
            throw IdentityError.invalidMnemonic
        }
        try ensureLoaded()
        for id in orderedIDs { try keychain.wipe(id) }
        let removed = orderedIDs
        cache.removeAll()
        names.removeAll()
        orderedIDs.removeAll()
        currentID = nil
        let id = try addLocked(name: nil, mnemonic: mnemonic)
        currentID = id
        persistSelection()
        for prev in removed {
            for cont in removalContinuations.values { cont.yield(prev) }
        }
        broadcast()
        guard let identity = cache[id] else { throw IdentityError.identityNotLoaded }
        return identity
    }

    /// Wipe every identity. Subscribers receive nil.
    func wipe() throws {
        try ensureLoaded()
        for id in orderedIDs { try keychain.wipe(id) }
        let removed = orderedIDs
        cache.removeAll()
        names.removeAll()
        orderedIDs.removeAll()
        currentID = nil
        persistSelection()
        for id in removed {
            for cont in removalContinuations.values { cont.yield(id) }
        }
        broadcast()
    }

    // MARK: - Read

    /// The currently-selected identity, or nil if none exists. Reading
    /// this does not trigger a Keychain reload.
    func currentIdentity() -> Identity? {
        guard let currentID else { return nil }
        return cache[currentID]
    }

    /// The currently-selected identity's ID, or nil if none. Used by
    /// the chain layer to stamp `ChatGroup.ownerIdentityID` at create
    /// time without reaching back into the keychain.
    func currentSelectedID() -> IdentityID? {
        currentID
    }

    /// The currently-selected identity's user-visible alias, or nil
    /// if no identity is selected. Cheap actor-local read against the
    /// in-memory `names` cache; callers that stamp the alias into
    /// outgoing wire payloads (e.g. creator's `MemberProfile` at
    /// group-create time) read this once at send time and don't
    /// re-resolve later — a rename after the fact doesn't backfill
    /// already-shipped state.
    func currentIdentityName() -> String? {
        guard let currentID else { return nil }
        return names[currentID]
    }

    /// Snapshot of every identity, ordered by insertion. View-safe
    /// (no secret material).
    func currentIdentities() -> [IdentitySummary] {
        orderedIDs.compactMap(summary(for:))
    }

    /// One-shot accessor for the currently-selected identity's BLS Fr
    /// scalar. Used by the chain layer (`OnymGroupProofGenerator`) to
    /// call `Tyranny.proveCreate` etc. Loads from the Keychain on
    /// every call (no in-memory cache); callers MUST NOT retain the
    /// returned bytes beyond the immediate proof-generation hop.
    func blsSecretKey() throws -> Data {
        guard let currentID else {
            throw IdentityError.identityNotLoaded
        }
        guard let snapshot = try keychain.read(currentID) else {
            throw IdentityError.identityNotLoaded
        }
        return snapshot.blsSecretKey
    }

    // MARK: - Streams

    nonisolated var snapshots: AsyncStream<Identity?> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribeSnapshot(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribeSnapshot(id: id) }
            }
        }
    }

    nonisolated var identitiesStream: AsyncStream<[IdentitySummary]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribeIdentities(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribeIdentities(id: id) }
            }
        }
    }

    nonisolated var currentIdentityID: AsyncStream<IdentityID?> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribeCurrentID(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribeCurrentID(id: id) }
            }
        }
    }

    /// Fires once per removed identity. Used by `GroupRepository` (PR-3)
    /// to drop chats whose `ownerIdentityID` matches.
    nonisolated var identityRemoved: AsyncStream<IdentityID> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribeRemoval(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribeRemoval(id: id) }
            }
        }
    }

    // MARK: - Invitation decryption

    /// Decode an inbox-transport-delivered invitation envelope and open
    /// it with the **specified identity's** X25519 private key. The
    /// fan-out transport stamps each persisted invitation with the
    /// receiving identity's ID; callers pass that stamp here so the
    /// envelope decrypts under the right key — even when the receiving
    /// identity isn't the currently-selected one.
    func decryptInvitation(envelopeBytes: Data, asIdentity identityID: IdentityID) throws -> Data {
        guard let snapshot = try keychain.read(identityID) else {
            throw InvitationDecryptError.identityNotLoaded
        }
        let privateKey = try Self.inboxKeyAgreementPrivateKey(
            fromNostrSecret: snapshot.nostrSecretKey
        )
        return try Self.decryptSealedEnvelope(
            envelopeBytes: envelopeBytes,
            recipientX25519PrivateKey: privateKey
        )
    }

    /// Single-pass decrypt that surfaces the sender's Ed25519 pubkey
    /// alongside the plaintext. Overrides the protocol's default
    /// (which would re-decode the envelope twice) — at our volume
    /// the savings are tiny but it's the right factoring.
    func decryptInvitationWithSender(
        envelopeBytes: Data,
        asIdentity identityID: IdentityID
    ) throws -> DecryptedEnvelope {
        guard let snapshot = try keychain.read(identityID) else {
            throw InvitationDecryptError.identityNotLoaded
        }
        let privateKey = try Self.inboxKeyAgreementPrivateKey(
            fromNostrSecret: snapshot.nostrSecretKey
        )
        let envelope: SealedEnvelope
        do {
            envelope = try JSONDecoder().decode(SealedEnvelope.self, from: envelopeBytes)
        } catch {
            throw InvitationDecryptError.malformedEnvelope
        }
        let plaintext = try Self.decryptSealedEnvelope(
            envelope: envelope,
            recipientX25519PrivateKey: privateKey
        )
        return DecryptedEnvelope(
            plaintext: plaintext,
            senderEd25519PublicKey: envelope.senderEd25519PublicKey
        )
    }

    /// Static decrypt for callers that already hold the X25519 private
    /// key — used by `JoinRequestApprover` to open envelopes sealed
    /// to a per-invite ephemeral introPub (where the matching privkey
    /// lives in `IntroKeyStore`, not in the identity keychain).
    ///
    /// Same wire-format guarantees as `decryptInvitation(envelopeBytes:asIdentity:)`:
    /// requires `scheme = "x25519-aes-256-gcm-v1"`, verifies the
    /// optional Ed25519 signature on the ephemeral pubkey when
    /// present, runs ECDH + HKDF + AES-GCM open.
    static func decryptSealedEnvelope(
        envelopeBytes: Data,
        recipientX25519PrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        let envelope: SealedEnvelope
        do {
            envelope = try JSONDecoder().decode(SealedEnvelope.self, from: envelopeBytes)
        } catch {
            throw InvitationDecryptError.malformedEnvelope
        }
        return try decryptSealedEnvelope(
            envelope: envelope,
            recipientX25519PrivateKey: recipientX25519PrivateKey
        )
    }

    /// Same as `decryptSealedEnvelope(envelopeBytes:...)` but operates
    /// on a pre-decoded envelope. Lets the caller fish out fields like
    /// `senderEd25519PublicKey` without paying for a second JSON
    /// decode of the same bytes.
    static func decryptSealedEnvelope(
        envelope: SealedEnvelope,
        recipientX25519PrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        guard envelope.scheme == "x25519-aes-256-gcm-v1" else {
            throw InvitationDecryptError.unsupportedScheme(envelope.scheme)
        }
        guard let ephPubData = envelope.ephemeralPublicKey else {
            throw InvitationDecryptError.missingEphemeralKey
        }
        guard let nonceData = envelope.nonce, let tag = envelope.authenticationTag else {
            throw InvitationDecryptError.missingNonceOrTag
        }

        // M-5 / N-1: verify Ed25519 signature on the ephemeral pubkey
        // when present.
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

        do {
            let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubData)
            let sharedSecret = try recipientX25519PrivateKey.sharedSecretFromKeyAgreement(with: ephPub)
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

    /// Sender-side mirror of `decryptInvitation`. Uses the currently-
    /// selected identity's nostr secret to derive the per-envelope
    /// ECDH and Ed25519 signing keys.
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

        guard let currentID else {
            throw InvitationSealError.identityNotLoaded
        }
        guard let snapshot = try keychain.read(currentID) else {
            throw InvitationSealError.identityNotLoaded
        }
        let signingKey = try Self.stellarSigningPrivateKey(
            fromNostrSecret: snapshot.nostrSecretKey
        )

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

    // MARK: - Private (lifecycle)

    /// Lazy load every identity from the keychain on first call.
    /// Resolves the previously-selected identity from
    /// `selectionStore`; falls back to the first identity if the
    /// stored selection no longer exists.
    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        let ids = try keychain.list()
        // Stable order — UUIDs sort lexically. The picker also re-sorts
        // by name, so this is just a determinism guarantee for the
        // underlying storage.
        let sorted = ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        for id in sorted {
            guard let snapshot = try keychain.read(id) else { continue }
            cache[id] = try Self.identity(from: snapshot)
            names[id] = snapshot.name ?? Self.fallbackName(for: id, in: sorted)
            orderedIDs.append(id)
        }
        if let restored = selectionStore.load(),
           cache[restored] != nil {
            currentID = restored
        } else {
            currentID = orderedIDs.first
            if currentID != nil { persistSelection() }
        }
    }

    /// Mints a fresh BIP39 identity (or restores from `mnemonic` when
    /// non-nil), persists it under a new `IdentityID`, and inserts
    /// into the in-memory cache. Does NOT broadcast or touch
    /// `currentID`; callers do.
    private func addLocked(name: String?, mnemonic: String?) throws -> IdentityID {
        var entropy: Data
        if let mnemonic {
            guard Bip39.isValidMnemonic(mnemonic),
                  let parsed = Bip39.entropyFromMnemonic(mnemonic)
            else {
                throw IdentityError.invalidMnemonic
            }
            entropy = parsed
        } else {
            let fresh = Bip39.generateMnemonic()
            guard let parsed = Bip39.entropyFromMnemonic(fresh) else {
                throw IdentityError.invalidMnemonic
            }
            entropy = parsed
        }
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        let id = IdentityID()
        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.fallbackName(forNewSlot: orderedIDs.count + 1)
        var snapshot = Self.snapshot(fromEntropy: entropy)
        snapshot.name = resolvedName
        try keychain.write(id, snapshot)
        let identity = try Self.identity(from: snapshot)
        cache[id] = identity
        names[id] = resolvedName
        orderedIDs.append(id)
        return id
    }

    private func summary(for id: IdentityID) -> IdentitySummary? {
        guard let identity = cache[id] else { return nil }
        return IdentitySummary(
            id: id,
            name: names[id] ?? Self.fallbackName(forNewSlot: 1),
            blsPublicKey: identity.blsPublicKey,
            inboxPublicKey: identity.inboxPublicKey
        )
    }

    private func persistSelection() {
        selectionStore.save(currentID)
    }

    private func broadcast() {
        let summaries = orderedIDs.compactMap(summary(for:))
        for cont in identitiesContinuations.values { cont.yield(summaries) }
        for cont in currentIDContinuations.values { cont.yield(currentID) }
        let active = currentID.flatMap { cache[$0] }
        for cont in snapshotContinuations.values { cont.yield(active) }
    }

    // MARK: - Subscription bookkeeping

    private func subscribeSnapshot(
        id: UUID,
        continuation: AsyncStream<Identity?>.Continuation
    ) {
        snapshotContinuations[id] = continuation
        continuation.yield(currentID.flatMap { cache[$0] })
    }
    private func unsubscribeSnapshot(id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func subscribeIdentities(
        id: UUID,
        continuation: AsyncStream<[IdentitySummary]>.Continuation
    ) {
        identitiesContinuations[id] = continuation
        continuation.yield(orderedIDs.compactMap(summary(for:)))
    }
    private func unsubscribeIdentities(id: UUID) {
        identitiesContinuations.removeValue(forKey: id)
    }

    private func subscribeCurrentID(
        id: UUID,
        continuation: AsyncStream<IdentityID?>.Continuation
    ) {
        currentIDContinuations[id] = continuation
        continuation.yield(currentID)
    }
    private func unsubscribeCurrentID(id: UUID) {
        currentIDContinuations.removeValue(forKey: id)
    }

    private func subscribeRemoval(
        id: UUID,
        continuation: AsyncStream<IdentityID>.Continuation
    ) {
        removalContinuations[id] = continuation
    }
    private func unsubscribeRemoval(id: UUID) {
        removalContinuations.removeValue(forKey: id)
    }

    // MARK: - Snapshot → Identity derivation

    private static func snapshot(fromEntropy entropy: Data) -> StoredSnapshot {
        let mnemonic = Bip39.mnemonicFromEntropy(entropy)
        var seed = Bip39.seedFromMnemonic(mnemonic)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return StoredSnapshot(
            name: nil,
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

    private static func stellarPublicKey(fromNostrSecret nostrSecret: Data) -> Data {
        let privateKey = (try? stellarSigningPrivateKey(fromNostrSecret: nostrSecret))!
        return Data(privateKey.publicKey.rawRepresentation)
    }

    private static func stellarSigningPrivateKey(
        fromNostrSecret nostrSecret: Data
    ) throws -> Curve25519.Signing.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: nostrSecret),
            salt: Data("app.onym.ios".utf8),
            info: Data("stellar-ed25519-v1".utf8),
            outputByteCount: 32
        )
        let seed = derived.withUnsafeBytes { Data($0) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    private static func inboxPublicKey(fromNostrSecret nostrSecret: Data) -> Data {
        let privateKey = (try? inboxKeyAgreementPrivateKey(fromNostrSecret: nostrSecret))!
        return Data(privateKey.publicKey.rawRepresentation)
    }

    private static func inboxKeyAgreementPrivateKey(
        fromNostrSecret nostrSecret: Data
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: nostrSecret),
            salt: Data("app.onym.ios".utf8),
            info: Data("x25519-key-agreement-v1".utf8),
            outputByteCount: 32
        )
        let seed = derived.withUnsafeBytes { Data($0) }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
    }

    private static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let hash = hasher.finalize()
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Naming helpers

    /// Synthetic display name when the stored snapshot doesn't carry
    /// one. N is the 1-based slot the identity occupies.
    static func fallbackName(forNewSlot slot: Int) -> String {
        slot == 1 ? "Identity" : "Identity \(slot)"
    }

    private static func fallbackName(for id: IdentityID, in ids: [IdentityID]) -> String {
        let position = (ids.firstIndex(of: id) ?? 0) + 1
        return fallbackName(forNewSlot: position)
    }
}

// MARK: - Selection persistence

/// Where the "currently-selected identity" preference lives across
/// app launches. Production uses `UserDefaults`; tests use the
/// in-memory variant.
struct SelectedIdentityStore: Sendable {
    let load: @Sendable () -> IdentityID?
    let save: @Sendable (IdentityID?) -> Void

    static let userDefaults: SelectedIdentityStore = {
        let key = "app.onym.ios.identity.selectedID"
        return SelectedIdentityStore(
            load: {
                guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
                return IdentityID(raw)
            },
            save: { id in
                if let id {
                    UserDefaults.standard.set(id.rawValue.uuidString, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        )
    }()

    static func inMemory(initial: IdentityID? = nil) -> SelectedIdentityStore {
        let box = MutableBox(value: initial)
        return SelectedIdentityStore(
            load: { box.value },
            save: { box.value = $0 }
        )
    }

    /// Tiny mutable box for the in-memory variant. Sendable via NSLock.
    private final class MutableBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: IdentityID?
        var value: IdentityID? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
        init(value: IdentityID?) { self._value = value }
    }
}

// MARK: - String helpers

private extension String {
    /// Returns nil when self is empty; useful in `?? "fallback"` chains.
    var nonEmpty: String? { isEmpty ? nil : self }
}
