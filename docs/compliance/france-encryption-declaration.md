# French Encryption Declaration — Onym (iOS)

*Déclaration relative à un moyen de cryptologie — fourniture / importation*

This is the declaration to upload in **App Store Connect** (App Store Connect
now forwards French encryption declarations to ANSSI on your behalf — you no
longer post it to ANSSI directly). Fill the bracketed `[…]` fields, export to
PDF, and attach it in App Store Connect → your app → **App Information →
Encryption Documentation** (see `README.md`).

Legal basis: Loi n° 2004-575 (LCEN), art. 30; Décret n° 2007-663. Onym
uses only standard algorithms, so this is a **declaration** (processed
within ~1 month), not an authorization.

---

## 1. Declarant (déclarant)

| Field | Value |
|---|---|
| Legal name / entity | `[Company legal name]` |
| Legal form | `[e.g. SAS / individual developer]` |
| Registration no. (SIREN/SIRET or equiv.) | `[…]` |
| Registered address | `[…]` |
| Country | `[…]` |
| Contact name | `[…]` |
| Email | `[…]` |
| Phone | `[…]` |
| Apple Team ID | `[…]` |

## 2. Product

| Field | Value |
|---|---|
| Product name | Onym |
| Bundle identifier | `app.onym.ios` |
| Version | `[e.g. 1.0]` |
| Nature of operation | Fourniture (supply) via the App Store, incl. France |
| Description | Onym is a privacy-first group messenger. Messages and media are end-to-end encrypted; identities are cryptographic keys (no phone number or email); group membership is anchored on a public ledger rather than a company-owned server. |
| Function of the cryptology | Confidentiality (end-to-end encryption of user messages and media) and authentication/integrity of messages and identities. |

## 3. Cryptographic characteristics

Onym implements **only publicly documented, industry-standard algorithms**.
No proprietary or secret confidentiality algorithm is used. Full detail:
`cryptography-inventory.md`.

**Confidentiality**
- AES-256-GCM (message, media, group-epoch, and at-rest encryption)
- X25519 (Curve25519) ECDH key agreement
- HKDF-SHA256 key derivation

**Authentication / integrity / key management**
- Ed25519 signatures
- secp256k1 BIP340 Schnorr signatures (Nostr transport)
- SHA-256 hashing
- BIP39 recovery phrase; PBKDF2-HMAC-SHA512 seed derivation
- Poseidon hash (zero-knowledge group-membership proofs)

**Maximum symmetric key length:** 256 bits (AES).
**Asymmetric primitives:** Curve25519 / Ed25519 / secp256k1 (256-bit class).

**Cryptographic provider:** Apple CryptoKit and Apple CommonCrypto, plus
standard open implementations of secp256k1/Poseidon. Confidentiality relies
on Apple platform cryptography.

## 4. Distribution

- Channel: Apple App Store.
- Availability: worldwide, **including France**.
- Audience: general public (mass-market).
- Source availability: `[public repo URL, if applicable]`.

## 5. Supporting material

- Commercial/technical description: this document + `cryptography-inventory.md`.
- App Store listing: `[App Store URL once live]`.

---

**Declaration.** The undersigned declares that the above information is
accurate and that Onym supplies a means of cryptology as described, using
standard algorithms, in accordance with the applicable French regulations.

Name: `[…]`   Title: `[…]`   Date: `[…]`   Signature: `[…]`
