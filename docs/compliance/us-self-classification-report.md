# US Encryption Self-Classification Report — Onym (iOS)

Onym qualifies as **mass-market encryption software**, ECCN **5D992.c**,
exported under License Exception **ENC** per US EAR §740.17(b)(1). That
route requires an annual **self-classification report** emailed to BIS and
NSA (no CCATS needed, because Onym uses only standard algorithms).

This is what Apple's export-compliance flow refers to when it asks whether
your app "qualifies for any of the exemptions" — Onym does **not** qualify
for the narrow exemptions (it does E2E encryption beyond HTTPS), so
`ITSAppUsesNonExemptEncryption = true` and this report is the compliance basis.

## When to file

- Once, before/at first distribution, **and**
- Every year by **February 1** covering the prior calendar year, as long as
  the product is available and its crypto is materially unchanged.

## How to file

Email a CSV/plain-text report to **both**:
- `crypt@bis.doc.gov`
- `enc@nsa.gov`

The report is a supplement-format table (EAR Supp. No. 8 to Part 742). Send
one row per product.

## Report content (one row)

| Column | Value |
|---|---|
| Product name / model | Onym (iOS) |
| ECCN | 5D992.c |
| Authorization type | Self-classification (740.17(b)(1)) |
| Manufacturer | `[Company legal name]` |
| Item type | Application software — end-to-end encrypted messenger |
| Encryption used | AES-256-GCM; X25519 ECDH; HKDF-SHA256; Ed25519; secp256k1 Schnorr; SHA-256; PBKDF2-HMAC-SHA512 |
| Symmetric key length | 256 bits |
| Asymmetric key length | Curve25519 / Ed25519 / secp256k1 (256-bit class) |
| Non-standard crypto | None |
| Open cryptographic interface | No |
| Description | Group messenger providing E2E confidentiality of user messages and media using standard algorithms. |

See `cryptography-inventory.md` for the full technical basis.

## Notes

- If the algorithm set materially changes (e.g. a new confidentiality
  algorithm), update `cryptography-inventory.md` and re-file.
- Consult counsel before filing; export classification is the developer's
  legal responsibility. This document is preparatory, not legal advice.
