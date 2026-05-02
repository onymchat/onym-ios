# OnymIOS

iOS app for Onym, built incrementally on top of
[`onym-sdk-swift`](https://github.com/onymchat/onym-sdk-swift).

This repo is being grown from scratch — small, hand-reviewable chunks.
Chunk 1 wired in the OnymSDK Swift Package. Chunk 2 lands the
persistent reactive identity repository.

## Setup

```sh
brew install xcodegen
./generate-xcodeproj.sh
open OnymIOS.xcodeproj
```

`project.yml` is the source of truth for the Xcode project.
`*.xcodeproj/` is gitignored so we never deal with `pbxproj` merge
conflicts. Re-run `./generate-xcodeproj.sh` after pulling, or any
time `project.yml` changes.

## Architecture

Three rules, enforced by file layout and access modifiers:

- **Repositories own all I/O** — Keychain, network, on-device state.
  Pure references; no UI.
- **Unidirectional reactive flow to views** — repositories publish
  state; views observe and render; user actions flow back as intents
  that mutate repository state. No bidirectional bindings, no shared
  mutable state across views.
- **OnymSDK is internal-only** — repositories wrap it; views never
  call it directly.
- **Secret material stays inside its owning repository** — outside
  callers must not read mnemonic / private-key fields off any value
  type that exposes them. Statically enforced — see *Static checks*.

The first repository — `IdentityRepository` — is an `actor` that
publishes identity snapshots via `AsyncStream<Identity?>`. Views
subscribe with `.task` and re-render whenever a new snapshot lands;
they never see secret material, never call OnymSDK, never touch the
Keychain.

## Current state

```
.
├── project.yml                              ← xcodegen source of truth
├── generate-xcodeproj.sh                    ← regenerates OnymIOS.xcodeproj
├── Resources/
│   └── Localizable.xcstrings                ← single-file String Catalog (en + ru)
├── Gemfile                                  ← fastlane gem
├── fastlane/
│   ├── Fastfile                             ← `release` lane: match adhoc + gym
│   ├── Appfile                              ← bundle id + team
│   └── Matchfile                            ← match repo URL + readonly defaults
├── .github/workflows/
│   └── release.yml                          ← lint → tests → IPA → GH Release
├── scripts/
│   └── lint-secrets.py                      ← static check: no off-repo secret reads
├── Sources/OnymIOS/
│   ├── OnymIOSApp.swift                     ← @main, holds repo + authenticator
│   ├── Identity/
│   │   ├── Identity.swift                   ← Sendable value type the views see
│   │   ├── IdentityRepository.swift         ← actor + AsyncStream snapshots
│   │   ├── KeychainStore.swift              ← single-blob Codable in Keychain
│   │   ├── IdentityError.swift              ← single error type
│   │   ├── Bip39.swift                      ← BIP39 wordlist + PBKDF2 + HKDF
│   │   └── StellarStrKey.swift              ← Ed25519 → G... account ID encoder
│   └── Recovery/
│       ├── RecoveryPhraseBackupView.swift   ← root view + Intro/Reveal/Verify/Done
│       ├── RecoveryPhraseBackupFlow.swift   ← @Observable @MainActor view-model
│       └── BiometricAuthenticator.swift     ← protocol + LAContext impl
├── Tests/OnymIOSTests/
│   ├── SmokeTests.swift                     ← OnymSDK wiring sanity check
│   ├── IdentityRepositoryTests.swift        ← real-Keychain integration tests
│   └── RecoveryPhraseBackupFlowTests.swift  ← flow with real repo + fake auth
└── README.md
```

Bundle id is `chat.onym.ios` (production) — same as the reference
impl currently shipping from `stellar-mls/clients/ios`. As long as
both repos exist in parallel they'll fight over the same install
slot on a device; coordinate the cutover when promoting onym-ios to
the production build.

Project options match the reference impl: deployment target iOS
26.0, Xcode 26.0, the same `INFOPLIST_KEY_*` set (orientations,
indirect input events, scene manifest), `TARGETED_DEVICE_FAMILY`
1+2 (iPhone + iPad), `DEVELOPMENT_TEAM` from environment so unsigned
builds work without local config.

## Identity persistence

One Keychain item (`kSecClassGenericPassword`, service
`chat.onym.ios.identity`) holds a JSON-encoded `StoredSnapshot`:

```swift
struct StoredSnapshot: Codable {
    let entropy: Data?           // 16 bytes (BIP39 128-bit entropy)
    let nostrSecretKey: Data     // 32 bytes (secp256k1)
    let blsSecretKey: Data       // 32 bytes (BLS12-381 Fr)
}
```

Single-blob layout means every mutation is one atomic `SecItemUpdate`
(or `SecItemAdd`) — there is no intermediate state where one secret
has been written and another has not. Accessibility:
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (survives reboot,
never leaves the device, no iCloud Keychain sync).

## Derivation

`Identity` exposes four public keys plus two derived identifiers.
Two pairs are persisted (nostr + BLS); the other two are HKDF-derived
from the nostr secret on every load. The private halves of the
derived pairs stay inside the repository.

```
                ┌─────────────────────────────────────┐
                │  BIP39 mnemonic  (12 words)         │
                └────────────────┬────────────────────┘
                                 │ PBKDF2-HMAC-SHA512  (2048 iters)
                                 ▼
                ┌─────────────────────────────────────┐
                │  64-byte seed                       │
                └────────┬────────────────┬───────────┘
                         │                │     HKDF-SHA256
                         ▼                ▼     salt = "chat.onym.bip39"
              ┌──────────────────┐ ┌──────────────────┐
              │ nostr secret     │ │ BLS secret       │
              │ (32B secp256k1)  │ │ (32B BLS Fr)     │
              └────┬─────────────┘ └────────┬─────────┘
                   │ HKDF-SHA256              │
                   │ salt = "chat.onym.ios"   │
       ┌───────────┼───────────────┐          │
       ▼           ▼               ▼          │
  ┌─────────┐ ┌─────────────┐ ┌─────────────┐ │
  │ Stellar │ │  X25519     │ │ inboxTag    │ │
  │ Ed25519 │ │  (key agr.) │ │ (16-hex)    │ │
  │ → G...  │ │  → inbox    │ │ SHA-256     │ │
  └─────────┘ └─────────────┘ │ ("sep-      │ │
                              │  inbox-v1"  │ │
                              │  ‖ X25519   │ │
                              │   pubkey)   │ │
                              │   [0..8]    │ │
                              └─────────────┘ │
                                              │
                                              ▼
                              48B BLS12-381 G1 compressed pubkey
```

Constants are byte-identical to the reference impl
(`stellar-mls/clients/ios/StellarChat`) so a recovery phrase
generated there restores the same identity here, and vice versa.
**Don't change these without coordinating every client.**

| Step | Input | Salt | Info | Algorithm |
|---|---|---|---|---|
| Seed                  | mnemonic       | `"mnemonic"+passphrase` | —                          | PBKDF2-HMAC-SHA512, 2048 iters |
| Nostr secret          | seed           | `chat.onym.bip39`       | `nostr-secp256k1-v1`       | HKDF-SHA256, 32B |
| BLS secret            | seed           | `chat.onym.bip39`       | `bls12-381-v1`             | HKDF-SHA256, 32B |
| Stellar Ed25519 seed  | nostr secret   | `chat.onym.ios`         | `stellar-ed25519-v1`       | HKDF-SHA256, 32B |
| X25519 seed (inbox)   | nostr secret   | `chat.onym.ios`         | `x25519-key-agreement-v1`  | HKDF-SHA256, 32B |
| Inbox tag             | X25519 pubkey  | —                       | prefix `sep-inbox-v1`      | SHA-256, hex(prefix(8)) |
| Stellar account ID    | Ed25519 pubkey | —                       | version byte `6 << 3 = 48` | StrKey (CRC16-XMODEM + base32) |

`IdentityRepositoryTests.test_derivation_matchesCrossPlatformFixture`
locks the entire chain in against the canonical BIP39 test vector
(`abandon × 11 + about`). Any drift in any constant breaks that test
loudly.

### Why all four pubkeys live on `Identity`

| Field | Used by |
|---|---|
| `nostrPublicKey` (32B secp256k1)    | Nostr event verification; npub display |
| `blsPublicKey` (48B BLS12-381)      | SEP group membership trees + plonk proofs |
| `stellarPublicKey` (32B Ed25519)    | Transport bundles; attestations; envelope-sig verification |
| `stellarAccountID` (`G...`)         | `callerAddress` on every Soroban contract call |
| `inboxPublicKey` (32B X25519)       | ECDH target — peers encrypt invitations to us against this |
| `inboxTag` (16-hex)                 | Nostr `#t`/`#d` filter — addresses invites to our inbox |

All are deterministic from the persisted secrets, so the repository
computes them once at load and ships precomputed bytes on the
snapshot. Views read precomputed values; they never trigger an FFI
call or HKDF derivation.

The Stellar Ed25519 and X25519 **private** keys never leave the
repository. When signing / decryption methods land (next chunks),
they'll be `repo.stellarSign(_:)` / `repo.decryptInvitation(_:)` —
not raw private-key access on `Identity`.

## Reactive shape

```
                 ┌──────────────────────────────────┐
                 │  actor IdentityRepository        │
                 │                                  │
                 │  bootstrap / generateNew /       │
                 │  restore  / wipe                 │
                 │       │                          │
                 │       ▼                          │
                 │  apply(Identity?)                │
                 │       │                          │
                 │       └─► yield to N AsyncStream │
                 │           continuations          │
                 └──────────────┬───────────────────┘
                                │  AsyncStream<Identity?>
                                ▼
                 ┌──────────────────────────────────┐
                 │  SwiftUI View                    │
                 │  .task {                         │
                 │      for await snap in repo      │
                 │          .snapshots {            │
                 │              identity = snap     │
                 │      }                           │
                 │  }                               │
                 └──────────────────────────────────┘
```

The actor's executor serialises mutation; Keychain reads/writes,
PBKDF2, HKDF, and OnymSDK FFI all run off the main thread by
construction. Subscribers receive the current value immediately on
subscribe, then a fresh value after every successful mutation.

## Recovery-phrase backup flow

The app currently boots straight into the "Back up keys" flow — the
only screen wired up so far. The flow is the first piece of UI built
on top of `IdentityRepository`, and it's the template for every
subsequent flow: state lives in an `@Observable @MainActor`
view-model; the view reads `flow.step` and emits intents; all side
effects (`LAContext`, `UIPasteboard`, randomness, `Task.sleep`) are
behind the flow boundary.

```
                     IdentityRepository (actor)
                              │  AsyncStream<Identity?>
                              ▼
   RecoveryPhraseBackupFlow (@Observable @MainActor)
   ┌─────────────────────────────────────────────────┐
   │  step:  .intro                                  │
   │       │ tappedContinueFromIntro                 │
   │       ▼                                         │
   │       authenticate() ── LAContext (via          │
   │       │                  BiometricAuthenticator)│
   │       ▼                                         │
   │       .authFailed(reason) ◄── on failure        │
   │       │ dismissedAuthError                      │
   │       │                                         │
   │       ▼ on success + identity ready             │
   │       .reveal(phrase, revealed: false)          │
   │       │ tappedReveal                            │
   │       ▼                                         │
   │       .reveal(phrase, revealed: true)           │
   │       │ tappedCopyPhrase ── UIPasteboard        │
   │       │                     (auto-clear 60s)    │
   │       │ tappedContinueFromReveal                │
   │       ▼                                         │
   │       .verify(rounds: 3, index: 0, .idle)       │
   │       │ picked(word:)                           │
   │       │   correct → state .correct, sleep 450ms │
   │       │             then advance index OR done  │
   │       │   wrong   → state .wrong(word), retry   │
   │       ▼                                         │
   │       .done                                     │
   │       │ tappedDoneFromCompletion                │
   │       └──► back to .intro (single-screen app)   │
   └─────────────────────────────────────────────────┘
                              ▲
                              │ intents
                              │
                  RecoveryPhraseBackupView (SwiftUI)
                  reads flow.step, dispatches intents
```

The view never mutates state or calls OnymSDK; it doesn't even know
about `IdentityRepository` directly. The flow's `start()` method
bootstraps the repository and drains snapshots into a private
`currentIdentity`. The Continue button on intro is gated on
`flow.isReady` so a too-eager tap on first launch can't race the
bootstrap write.

The verify step picks 3 of 12 word positions at random, presents
each as a 4-way multiple choice with the correct word + 3 distractors
from the same phrase. On a wrong pick the user retries the same
round; on three corrects in a row, the flow advances to `.done`.

`BiometricAuthenticator` is a one-method protocol so the flow's
unit tests can drive it without standing up a real `LAContext` (which
needs UI presentation). `PasteboardWriter` plays the same role for
`UIPasteboard` — tests use a fake that records what was written.

13 XCTest cases in `RecoveryPhraseBackupFlowTests` cover every
transition (intro → reveal → verify → done, auth failure, copy +
auto-clear, wrong-pick retry, in-flight advance idempotency). Real
`IdentityRepository` per test (unique Keychain service for
isolation), seeded with a known mnemonic via `restore(mnemonic:)` so
the recovery phrase is deterministic.

## Localization

Strings live in a single Xcode 15+ **String Catalog** at
`Resources/Localizable.xcstrings` (sourceLanguage `en`). Currently
shipped languages:

- `en` — English (development language, source of truth)
- `ru` — Russian (full coverage)

The catalog is one JSON file holding every locale, so a translator
gets exactly one artifact to work with — no `.strings` per language,
no merge conflicts when two PRs touch different locales. Xcode
compiles each entry into per-locale `.strings` (or `.stringsdict`
for plural variants) inside the app bundle at build time.

**How to use a string in code:**

```swift
// Inside SwiftUI — automatic; the LocalizedStringKey initializer picks
// up the catalog entry by key.
Text("Back up keys")
Button("I've written it down") { ... }
.navigationTitle("Recovery phrase")     // returns LocalizedStringKey

// Outside SwiftUI (passing to LAContext, a String? property, etc.) —
// explicit String(localized:):
let reason = String(localized: "Authenticate to reveal your recovery phrase")
let footer = String(localized: "Backed up \(date) · BIP-39 English")
```

Xcode auto-extracts string literals passed to `Text`,
`LocalizedStringKey`, `String(localized:)`, etc. from source on every
build and adds them to the catalog with a `new` state. Translators
then provide the localized value in the Xcode editor (or by hand-
editing the JSON).

**Plurals (Russian-style):** `Localizable.xcstrings` supports CLDR
plural variations natively (`one` / `few` / `many` / `other` etc.).
The "Write down these %lld words" entry has `one`/`few`/`other`
forms in Russian so 1 word → "слово", 2-4 → "слова", 5+/12/24 →
"слов". English needs only `one`/`other`.

**Adding a new language:**

1. Open `Resources/Localizable.xcstrings` in Xcode.
2. Click `+` in the language sidebar, pick the new locale.
3. Translate each entry (Xcode shows source-language value as the
   reference; mark each unit `state: translated` when done).
4. Re-run `./generate-xcodeproj.sh` only if `project.yml` changed
   (it doesn't for new languages).

**Catching missing translations** — Xcode shows untranslated entries
as a warning in the catalog editor. CI doesn't currently fail on
missing translations; if/when we want that gate, run a script that
parses the catalog JSON and asserts every entry has a `translated`
state for every shipped language.

## Static checks

`scripts/lint-secrets.py` is a default-deny static check that fails
the build on any read of identity secrets — `.nostrSecretKey`,
`.blsSecretKey`, `.recoveryPhrase`, `.entropy` — outside the
allowlisted files (the repository, its persistence layer, the
identity value type, and its tests). The goal: catch accidental
secret leaks at the diff level, not after they've shipped to logs /
crash reports / screenshots.

Run before pushing:

```sh
python3 scripts/lint-secrets.py
```

To intentionally read a secret (e.g. a future biometric-gated
recovery-phrase reveal), annotate with `// onym:allow-secret-read`
on the line itself or anywhere in the contiguous `//`-comment block
directly above. Each suppression should justify itself in code review:

```swift
// Rendered behind biometric on the recovery-phrase backup screen —
// production reveal UI gates this and disables screenshots.
// onym:allow-secret-read
let phrase = identity.recoveryPhrase
```

The check runs in CI as the first job of the Release workflow (see
*Releasing*). Adding a file to the allowlist requires editing the
script and naming the reason in the PR.

## Releasing

`gh workflow run Release -f tag=vX.Y.Z` runs
`.github/workflows/release.yml`, which gates the IPA on:

1. **Lint** (`scripts/lint-secrets.py`, ubuntu) — no off-repo
   secret reads. Hard fail.
2. **Create release** (ubuntu) — generates notes from `git log
   <prev-tag>..HEAD` and opens an empty GitHub Release at the tag.
3. **Test** (self-hosted macOS ARM64) — `xcodebuild test` against an
   iPhone simulator.
4. **Build** (self-hosted macOS ARM64; needs all three above) —
   `bundle exec fastlane ios release` runs match (adhoc, readonly,
   git storage) → gym → produces a signed `OnymIOS-<version>.ipa`,
   which is uploaded to the release as an asset.

Lint, create-release, and test run in parallel; build only starts
when all three succeed. If lint fails the IPA never builds.

The structure was lifted from
`stellar-mls/.github/workflows/release.yml` — minus TestFlight
upload, OTA droplet rsync, Android, and the NotificationService
extension. Same Match repo / team / bundle id (`chat.onym.ios`) so
no new Apple Developer setup is needed.

### Required repo secrets

| Secret             | Purpose                                                |
|--------------------|--------------------------------------------------------|
| `MATCH_GIT_URL`    | git URL of the fastlane-match repo (cert/profile vault) |
| `MATCH_DEPLOY_KEY` | SSH private key with read access to that repo         |
| `MATCH_TEAM_ID`    | Apple Developer team ID                                |
| `MATCH_PASSWORD`   | encryption password for the match vault                |

TestFlight upload is intentionally skipped, so ASC API keys
(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_P8`) are NOT
needed for this workflow. Add them later if/when an App Store /
TestFlight lane lands.

The `[self-hosted, macOS, ARM64]` runner is shared with stellar-mls.
If you need to switch to a GitHub-hosted `macos-latest` runner,
replace the `runs-on` lines and budget for the Apple ecosystem
install steps (Xcode select, simulator runtime).

## Versioning

This repo tracks `OnymSDK` at `from: "0.0.1"`. Until the SDK hits
1.0, breaking changes can land in any minor bump — pin to a specific
version (`exact: "X.Y.Z"`) if reproducibility matters more than
auto-upgrade.

## License

MIT — see `LICENSE`.
