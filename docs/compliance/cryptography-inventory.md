# Onym — Cryptography Inventory

Authoritative list of every cryptographic mechanism Onym for iOS ships.
This is the technical annex referenced by both the **French encryption
declaration** and the **US self-classification report**. Keep it in sync
with the code — it is the single source of truth for compliance filings.

- **Product:** Onym (iOS)
- **Bundle identifier:** `app.onym.ios`
- **Category:** End-to-end encrypted group messenger
- **All algorithms:** industry-standard, publicly documented. **No
  proprietary or secret confidentiality algorithm is used.**
- **Primary crypto provider:** Apple CryptoKit + Apple CommonCrypto
  (`CCKeyDerivationPBKDF`). No bundled/statically-linked foreign crypto
  library provides confidentiality.

## 1. Confidentiality (encryption)

| Purpose | Algorithm | Key length | Source in repo |
|---|---|---|---|
| Message & payload E2E — sealed invitation envelopes | X25519 (ECDH) → HKDF-SHA256 → **AES-256-GCM** | 256-bit AES; Curve25519 | `Sources/OnymIOS/Identity/InvitationEnvelopeSealing.swift`, `Sources/OnymIOS/Inbox/InvitationDecryptor.swift` |
| Chat media (image / video / voice) blobs | **AES-256-GCM**, per-blob random key | 256-bit | `Sources/OnymIOS/Chats/ChatImageCrypto.swift`, `ChatVideoAttachment.swift`, `ChatVoiceAttachment.swift` |
| Group epoch content key | **AES-256-GCM** | 256-bit | `Sources/OnymIOS/Group/GroupCommitmentBuilder.swift` |
| Local at-rest field encryption | **AES-256-GCM**, key via HKDF-SHA256 from a Keychain-stored 32-byte root secret | 256-bit | `Sources/OnymIOS/Persistence/StorageEncryption.swift` |

## 2. Key agreement & derivation

| Purpose | Algorithm | Source |
|---|---|---|
| E2E key agreement (per-envelope ephemeral) | **X25519** ECDH (Curve25519) | `InvitationEnvelopeSealing.swift` |
| Symmetric-key derivation | **HKDF-SHA256** | `StorageEncryption.swift`, `Bip39.swift` |
| Seed derivation from recovery phrase | **PBKDF2-HMAC-SHA512** (BIP39) | `Sources/OnymIOS/Identity/Bip39.swift` |
| Recovery phrase | **BIP39** mnemonic | `Bip39.swift` |

## 3. Authentication & integrity (signing / hashing — not confidentiality)

| Purpose | Algorithm | Source |
|---|---|---|
| Identity / envelope attestation, Stellar keys | **Ed25519** signatures | `InvitationEnvelopeSealing.swift`, identity/chain layer |
| Nostr transport event signing | **secp256k1 BIP340 Schnorr** | `Sources/OnymIOS/Transport/Nostr/NostrSigner.swift`, `NostrEvent.swift` |
| Event IDs, entropy commitments | **SHA-256** | `NostrEvent.swift`, `Bip39.swift` |
| Zero-knowledge group-membership proofs | **Poseidon** hash (ZK-SNARK circuit) | group/chain layer |

> Signing, hashing, and the Poseidon ZK proof provide integrity /
> authentication / anonymity — **not** message confidentiality — but are
> listed here for completeness since ANSSI's declaration covers all
> cryptographic functions supplied.

## 4. Classification summary

- **Type:** standard/industry algorithms only → **French *declaration*
  (déclaration)**, not an *authorization* (autorisation). No US CCATS
  required.
- **US ECCN:** **5D992.c** (mass-market encryption software) under
  License Exception **ENC** — satisfied by an annual self-classification
  report to BIS + NSA. See `us-self-classification-report.md`.
- **France:** submit the declaration in `france-encryption-declaration.md`
  via App Store Connect. See `README.md` for the step-by-step.
