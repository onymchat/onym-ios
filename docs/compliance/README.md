# Encryption Export Compliance

Onym is an end-to-end encrypted messenger, so it uses **non-exempt
encryption** (real message/media encryption, beyond HTTPS). To ship it —
and specifically to make it **available in France** — a few compliance
artifacts are required. This folder holds them.

> Not legal advice. Export classification is the developer's legal
> responsibility; have counsel review before filing.

## TL;DR

| Question | Answer for Onym |
|---|---|
| Uses encryption beyond HTTPS? | **Yes** (E2E messaging) |
| `ITSAppUsesNonExemptEncryption` | **`true`** (set in `Info.plist`) |
| Proprietary/secret algorithm? | **No** — all standard (AES, X25519, …) |
| US: CCATS needed? | **No** — self-classify as 5D992.c (License Exception ENC) |
| France: declaration or authorization? | **Declaration** (standard algorithms) |
| Where the France declaration goes | Uploaded in **App Store Connect** (ASC forwards it to ANSSI) |

## Files here

- **`cryptography-inventory.md`** — every algorithm Onym uses. Source of
  truth; keep it in sync with the code. Feeds both filings below.
- **`france-encryption-declaration.md`** — fill in the `[…]` fields,
  export to PDF, upload in App Store Connect. This is the France ask.
- **`us-self-classification-report.md`** — the annual BIS/NSA email that
  backs the US 5D992.c mass-market classification.

## Making Onym available in France — step by step

1. **`Info.plist`** already sets `ITSAppUsesNonExemptEncryption = true`
   (with a comment explaining why). This stops App Store Connect from
   re-asking the encryption questions on every submission and commits us
   to the documented compliance path.
2. **Fill the French declaration.** Complete every `[…]` field in
   `france-encryption-declaration.md`, then export/print it to **PDF**.
3. **Upload it in App Store Connect:**
   - App Store Connect → **My Apps → Onym → App Information**.
   - Scroll to **App Encryption Documentation** (a.k.a. Export
     Compliance) and choose to provide documentation.
   - When asked about France, upload the PDF from step 2. ASC forwards
     the declaration to ANSSI on your behalf (the post-2024 process — no
     separate paper mailing to ANSSI).
   - Apple attaches the compliance status to the app version / build.
4. **File the US self-classification report** (`us-self-classification-report.md`)
   by emailing `crypt@bis.doc.gov` and `enc@nsa.gov`. Re-file annually by
   Feb 1 while the app is distributed.
5. **Confirm France is in the app's territory list** (App Store Connect →
   Pricing and Availability). With the declaration accepted, France can be
   left enabled.

## When crypto changes

If you add or change a confidentiality algorithm:
1. Update `cryptography-inventory.md`.
2. Re-check whether it's still "standard" (declaration) or now needs an
   authorization / CCATS.
3. Refresh the France declaration PDF in App Store Connect and re-file the
   US self-classification report.

## References

- Apple — [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- Apple — [Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/)
- ANSSI — <https://cyber.gouv.fr> (encryption declaration/authorization)
- US BIS — [Encryption policy / EAR](https://www.bis.doc.gov/index.php/policy-guidance/encryption)
