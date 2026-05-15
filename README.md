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

Four layers, each isolated from the others by an explicit seam.
Solid boxes exist today; dashed boxes are planned.

```
                                          ┌────────────────────────────────────┐
                                          │ Views (SwiftUI)                    │
                                          │ stateless · pure render            │
                                          │ RootView · SettingsView ·          │
                                          │ RecoveryPhraseBackupView           │
                                          └──────────┬──────────────▲──────────┘
                                                     │ intent       │ snapshot
                                                     ▼              │
                                          ┌──────────────────────────────────┐
                                          │ Interactors (@Observable)        │
                                          │ owns flow state · no domain      │
                                          │ state · UI-affordance I/O via    │
                                          │ small local seams                │
                                          │ RecoveryPhraseBackupFlow         │
                                          │ ╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶     │
                                          │ ╎ planned: ChatFlow · InviteFlow ╎│
                                          │ ╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶     │
                                          └──────────┬──────────────▲────────┘
                                                     │ command      │ snapshot
                                                     ▼              │
                                          ┌──────────────────────────────────┐
                                          │ Repositories (actors)            │
                                          │ stateful · own ALL I/O ·         │
                                          │ AsyncStream<T> reactive surface  │
                                          │                                  │
                                          │   IdentityRepository  ◄── ROOT   │
                                          │ ╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶     │
                                          │ ╎ planned: ChatRepository      ╎ │
                                          │ ╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶     │
                                          └──┬────────────────────────────┬──┘
                                             │                            │
                        ┌────────────────────┘                            └───────────────────┐
                        ▼                                                                     ▼
          ╔═══════════════════════╗                                       ╔══════════════════════════════╗
          ║ Persistence (seam)    ║                                       ║ Transport (seam)             ║
          ║ KeychainStore         ║                                       ║ MessageTransport             ║
          ║ ╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶   ║                                       ║ InboxTransport               ║
          ║ ╎ planned: SQLite ╎   ║                                       ║                              ║
          ║ ╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶   ║                                       ║                              ║
          ╚══════════╤════════════╝                                       ╚══════════╤═══════════════════╝
                     │                                                               │
                     ▼                                                               ▼
          ┌──────────────────────┐                              ┌────────────────────┬───────────────────────┐
          │ iOS Keychain         │                              │ Nostr (today)      │ ╎ planned: Tor       ╎│
          │ kSecClassGeneric…    │                              │ NostrRelayConn ·   │ ╎ HiddenServiceConn  ╎│
          └──────────────────────┘                              │ NostrEvent · NIP-01│ ╎ (drop-in adapter)  ╎│
                                                                └────────────────────┴───────────────────────┘
                                          ╔════════════════════════════════════╗
                                          ║ OnymSDK (FFI primitives)           ║
                                          ║ Common · Anarchy · OneOnOne ·      ║
                                          ║ Tyranny — Plonk · Poseidon · BLS · ║
                                          ║ BIP340 Nostr signing               ║
                                          ║ imported only by narrow crypto     ║
                                          ║ adapters owned by Identity / Chain ║
                                          ║ / Group; never by views, flows,    ║
                                          ║ transport, or persistence          ║
                                          ╚════════════════════════════════════╝
```

### Touch-surface rules

What each layer is allowed to call. Statically enforced where possible
(access modifiers, `scripts/lint-secrets.py`); load-bearing in code
review where it isn't.

| Layer | May call | Forbidden |
|---|---|---|
| **View** | its own interactor (intents in, snapshots out) · child-interactor factory closures from `AppDependencies` | repository directly · `OnymSDK` · Keychain · transport · `URLSession` · another interactor's internals |
| **Interactor** | repositories (commands + snapshots) · its own small UI-affordance seams (clipboard, biometric prompt, haptics) | `OnymSDK` · Keychain · transport · disk · network · persistence I/O · another interactor's internals |
| **Repository** | persistence seam · transport seam · `OnymSDK` (directly or via a repository-owned adapter like `OnymNostrSignerProvider`) | another repository's internals · views · interactors |
| **Persistence / Transport seam** | the one concrete backend it implements | repositories · `OnymSDK` · the other seam |
| **OnymSDK** | itself | everything above |

Two extra invariants that cut across the layers:

- **Secret material never becomes UI or shared state.** No outside
  caller reads `nostrSecretKey` / `blsSecretKey` / `entropy` /
  `recoveryPhrase` off `Identity` or any other snapshot value. The one
  intentional raw-secret hop is `IdentityRepository.blsSecretKey()` for
  immediate PLONK proof generation; callers must not retain, persist,
  log, or render that value. Enforced where possible by
  `scripts/lint-secrets.py` (default-deny diff check; see *Static
  checks*) and otherwise by review.
- **Reactive flow is unidirectional.** Repositories publish via
  `AsyncStream<T>`; interactors observe and command; views observe and
  intent. No bidirectional bindings, no shared mutable state across
  views, no view-side mutation.

### How to reason about the architecture

Reason from ownership, not from folder names alone. For any proposed
change, first ask which value is the source of truth and how long it
must live:

1. **Screen-only state belongs to a flow.** Text fields, selected
   pills, route/step enums, loading flags, and user-facing errors live
   in an `@Observable @MainActor` flow. The view reads fields and sends
   intents; it does not derive domain state or perform I/O.
2. **Durable or shareable state belongs to a repository.** Identity,
   relayer configuration, contract-anchor selection, groups, and
   incoming invitations are owned by actor repositories. If multiple
   screens need it, if it survives relaunch, or if it must replay to new
   subscribers, it is repository state.
3. **One-shot workflows belong to interactors.** If an operation spans
   multiple repositories and seams, make the interactor a stateless
   pipeline. It may coordinate dependencies and return a result, but it
   should not become the durable source of truth.
4. **Concrete I/O belongs behind a seam.** Keychain, UserDefaults,
   SwiftData, URLSession, Nostr relays, relayer POSTs, biometrics, and
   pasteboard access are accessed through a small protocol or local
   adapter. Tests swap the seam, not the caller.
5. **FFI belongs behind a named crypto adapter.** `OnymSDK` calls stay
   in narrow wrappers such as `IdentityRepository`,
   `OnymNostrSigner`, `OnymGroupProofGenerator`, or
   `GroupCommitmentBuilder`. Higher layers depend on their Swift
   contracts, not on SDK symbols.

The runtime shape is always:

```
view intent
  -> flow method
  -> repository command OR stateless interactor pipeline
  -> seam / crypto adapter / transport
  -> repository snapshot
  -> flow state
  -> view render
```

When a change feels awkward, inspect the direction of that loop. Most
architecture mistakes are a dependency trying to travel upward: a view
reaching into a repository, a flow doing network work, a transport
learning domain semantics, or an interactor keeping state that should
be replayed by a repository.

### Assumptions you can trust while working with this architecture

- `OnymIOSApp` is the composition root. It creates repositories and
  concrete seams once, then exposes only `AppDependencies` factory
  closures to views.
- Views do not own repositories. If a view needs behavior, add an
  intent to its flow or pass a child-flow factory through
  `AppDependencies`.
- Repositories are actors. They serialize mutation, own their backing
  store/fetcher/transport seam, and expose replaying `AsyncStream`
  snapshots. A successful mutation should publish a fresh snapshot.
- Flow types are `@Observable @MainActor`. They own transient UI state,
  drain repository snapshots with idempotent `start()` methods, and
  keep UI-only affordances behind local seams.
- Interactors are stateless coordinators. They can depend on multiple
  repositories and seams for one operation, but persistence happens by
  commanding the owning repository.
- Persistence and transport implementations are replaceable. Code above
  the seam should not know whether storage is Keychain, UserDefaults,
  SwiftData, in-memory, or whether transport is Nostr, URLSession, or a
  test fake.
- `OnymSDK` imports are exceptional and explicit. Adding a new SDK call
  means adding or extending a narrow adapter, plus tests for byte shape
  and cross-platform fixtures where applicable.
- Secret-bearing values are not rendered, logged, cached in flow state,
  or exposed on view snapshots. The BLS scalar may cross from
  `IdentityRepository` to proof generation only for the immediate
  create/update operation.

### Why this beats the reference impl in `stellar-mls/clients/ios`

- **Transport is a seam, not a class.** `MessageTransport` /
  `InboxTransport` are protocols; the Nostr implementation is one of
  several possible adapters. A future Tor / hidden-service / `wss://`
  mesh / mock transport drops in without touching any caller above the
  seam. In the reference impl, `NostrMessageTransport` and chat code
  are co-mingled — chat semantics (`GroupCrypto`, BLS attestation,
  member tracking) live in the same file as relay framing, which is
  why a transport swap there is a refactor, not a substitution.
- **Persistence is a seam too.** `IdentityRepository` talks to a
  `KeychainStore` reference — swapping in a SQLite-backed or in-memory
  store for a different deployment / test environment is a constructor
  change, not a rewrite.
- **Interactors own flow state, not domain state.** The reference impl
  puts orchestration on `AppState`, a single `@Observable` god-object
  that mixes per-screen flow state with cross-cutting domain state. We
  split orchestration per-flow (`RecoveryPhraseBackupFlow` today,
  `ChatFlow` / `InviteFlow` later); each owns its own state machine and
  *only* its state machine — no shared mutable bag. Domain state stays
  in the repository.
- **Views never hold a repository reference.** `OnymIOSApp` constructs
  `AppDependencies` once with factory closures that capture the
  repositories. Views receive only the closures (`makeBackupFlow: () ->
  RecoveryPhraseBackupFlow`) and call them when they need a fresh
  interactor. The compiler can't accidentally dot-access a repository
  from a view because views never see the type.
- **`OnymSDK` is callable only from narrow crypto adapters.** The
  `Transport/Nostr/` seam imports zero `OnymSDK` symbols — it asks an
  injected `NostrEphemeralSignerProvider` for a fresh signer per
  outgoing event. Group proof and commitment code follow the same
  shape: callers see `GroupProofGenerator` /
  `GroupCommitmentBuilder`, not raw SDK entrypoints.

### Why `IdentityRepository` is the cryptographic root

Identity is the only repository that owns long-lived device secrets and
derives the public identity surface from the Keychain. Relayer,
contracts, and group repositories can start without it, but any
operation that signs, decrypts, proves group membership, addresses an
inbox, or builds a Soroban caller address ultimately depends on
identity-derived material.

That makes `IdentityRepository` the cryptographic root, not a global
state bag. The app's `@main` constructs it first and bootstraps it
eagerly, then injects it only into interactors or adapters that need
identity-derived operations.

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
│   ├── OnymIOSApp.swift                     ← @main, repo + authenticator + test wiring
│   ├── RootView.swift                       ← TabView shell (Settings + Search role)
│   ├── Identity/
│   │   ├── Identity.swift                   ← Sendable value type the views see
│   │   ├── IdentityRepository.swift         ← actor + AsyncStream snapshots
│   │   ├── KeychainStore.swift              ← single-blob Codable in Keychain
│   │   ├── IdentityError.swift              ← single error type
│   │   ├── Bip39.swift                      ← BIP39 wordlist + PBKDF2 + HKDF
│   │   └── StellarStrKey.swift              ← Ed25519 → G... account ID encoder
│   ├── Recovery/
│   │   ├── RecoveryPhraseBackupView.swift   ← root view + Intro/Reveal/Verify/Done
│   │   ├── RecoveryPhraseBackupFlow.swift   ← @Observable @MainActor view-model
│   │   └── BiometricAuthenticator.swift     ← protocol + LAContext + DEBUG-only mock
│   ├── Settings/
│   │   └── SettingsView.swift               ← Form → Backup row → sheet
│   └── Search/
│       └── SearchView.swift                 ← placeholder for the .search role tab
├── Tests/OnymIOSTests/                      ← unit / integration (XCTest, in-process)
│   ├── SmokeTests.swift                     ← OnymSDK wiring sanity check
│   ├── IdentityRepositoryTests.swift        ← real-Keychain integration tests
│   └── RecoveryPhraseBackupFlowTests.swift  ← flow with real repo + fake auth
├── Tests/OnymIOSUITests/                    ← XCUITest, drives the live app
│   ├── RecoveryPhraseBackupUITests.swift    ← end-to-end flow coverage
│   ├── PageObjects/                         ← per-screen wrappers
│   │   ├── SettingsScreen.swift
│   │   ├── IntroScreen.swift
│   │   ├── RevealScreen.swift
│   │   ├── VerifyScreen.swift
│   │   └── DoneScreen.swift
│   └── Support/
│       └── AppLauncher.swift                ← fresh-launch helper with test args
└── README.md
```

Bundle id is `app.onym.ios` (production) — same as the reference
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
`app.onym.ios.identity`) holds a JSON-encoded `StoredSnapshot`:

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
                         ▼                ▼     salt = "app.onym.bip39"
              ┌──────────────────┐ ┌──────────────────┐
              │ nostr secret     │ │ BLS secret       │
              │ (32B secp256k1)  │ │ (32B BLS Fr)     │
              └────┬─────────────┘ └────────┬─────────┘
                   │ HKDF-SHA256              │
                   │ salt = "app.onym.ios"   │
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
| Nostr secret          | seed           | `app.onym.bip39`       | `nostr-secp256k1-v1`       | HKDF-SHA256, 32B |
| BLS secret            | seed           | `app.onym.bip39`       | `bls12-381-v1`             | HKDF-SHA256, 32B |
| Stellar Ed25519 seed  | nostr secret   | `app.onym.ios`         | `stellar-ed25519-v1`       | HKDF-SHA256, 32B |
| X25519 seed (inbox)   | nostr secret   | `app.onym.ios`         | `x25519-key-agreement-v1`  | HKDF-SHA256, 32B |
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

## UI tests

`Tests/OnymIOSUITests/` is a separate `bundle.ui-testing` target (its
own process, distinct from the in-process `OnymIOSTests` unit
bundle). Tests boot the real app via `XCUIApplication`, drive it
through the live SwiftUI views, and assert against the
accessibility tree.

### App-side test hooks

`OnymIOSApp.init` reads three launch arguments under `#if DEBUG` so
each test starts from a clean, deterministic state. Production
Release builds compile this code path out — there's no way for a
shipped binary to take the test-mode branch.

| arg                  | effect                                                                                |
|----------------------|---------------------------------------------------------------------------------------|
| `--ui-testing`       | Required gate. Without it the App ignores the other two args.                         |
| `--reset-keychain`   | Wipes the test-isolated keychain item before bootstrap.                               |
| `--mock-biometric`   | Swaps `LAContextAuthenticator` for `AlwaysAcceptAuthenticator` (DEBUG-only struct).   |

UI tests use a separate Keychain service
(`app.onym.ios.identity.uitests`) that is never touched by
production builds, so even a developer running tests on their own
device cannot disturb their real identity.

### Page-object pattern

Each screen has a `XYZScreen` struct in `PageObjects/` exposing the
elements and high-level actions tests need:

```swift
let app = AppLauncher.launchFresh(language: "en")
let settings = SettingsScreen(app: app)
settings.tapBackupRecoveryPhrase()

let intro = IntroScreen(app: app)
intro.tapContinue()                           // waits for isReady internally

let reveal = RevealScreen(app: app)
reveal.tapReveal()
let phrase = reveal.capturedPhrase()          // reads positions 1…12

let verify = VerifyScreen(app: app)
let position = verify.waitForRound()
verify.pick(word: phrase[position - 1])
```

Selectors are stable accessibility identifiers
(`reveal.word.<position>`, `verify.option.<word>`,
`settings.backup_recovery_phrase_row`, etc.) — never label text,
which would break the moment we localize a string or copy-edit a
button.

### How verify works without knowing the phrase

The flow generates 3 random rounds, each picking a random word
position and 4 random distractors. Tests can't predict which word
is correct without reading the phrase off the Reveal screen first
— so each test that exercises Verify reads the phrase via
`reveal.capturedPhrase()`, then on each Verify round looks up the
word at the requested position.

### Wiring & runtime

The `OnymIOS` scheme runs both `OnymIOSTests` and `OnymIOSUITests`
on `xcodebuild test` (no `-only-testing` flag needed). Defaults:

```sh
xcodebuild test \
  -project OnymIOS.xcodeproj \
  -scheme OnymIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/onym-ios-build
```

Wall-clock on iPhone 17 Pro simulator: ~89s for the full UI suite
(4 cases × ~22s/each, dominated by the simulator launch). Unit
tests still complete in ~1s. Run only the UI suite with
`-only-testing:OnymIOSUITests`.

The release pipeline (`.github/workflows/release.yml`) runs both
suites in its `test` job — same `xcodebuild test` invocation, same
`OnymIOS` scheme. UI tests are part of the release gate.

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
3. **Unit tests** (self-hosted macOS ARM64) — `xcodebuild test` with
   `-only-testing:OnymIOSTests`. Fast (~10–20 s on a warm runner).
4. **UI tests** (self-hosted macOS ARM64) — `xcodebuild test` with
   `-only-testing:OnymIOSUITests`. Pre-boots the iPhone simulator so
   the suite doesn't race the cold-boot. Slower (~90 s).
5. **Build** (self-hosted macOS ARM64; needs **all four** above) —
   `bundle exec fastlane ios release` runs match (adhoc, readonly,
   git storage) → gym → produces a signed `OnymIOS-<version>.ipa`,
   which is uploaded to the release as an asset.

```
   workflow_dispatch -f tag=vX.Y.Z
        │
        ├─► lint           (ubuntu)              ─┐
        ├─► create-release (ubuntu)              ─┤
        ├─► unit-tests     (self-hosted macOS)   ─┤  all four
        └─► ui-tests       (self-hosted macOS)   ─┘  must succeed
                                                       │
                                                       ▼
                                                  build (self-hosted)
                                                  fastlane match adhoc + gym
                                                       │
                                                       ▼
                                                  upload IPA to GH Release
```

All four gate jobs run in parallel; build only starts when every
one succeeds. If any test job fails its `.xcresult` bundle is
uploaded as a build artifact (named `unit-tests-xcresult` /
`ui-tests-xcresult`, retained 7 days) so the failure can be
inspected without re-running the workflow.

The structure was lifted from
`stellar-mls/.github/workflows/release.yml` — minus TestFlight
upload, OTA droplet rsync, Android, and the NotificationService
extension. Same Match repo / team / bundle id (`app.onym.ios`) so
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

This repo tracks `OnymSDK` at `from: "0.0.2"`. Until the SDK hits
1.0, breaking changes can land in any minor bump — pin to a specific
version (`exact: "X.Y.Z"`) if reproducibility matters more than
auto-upgrade.

## License

MIT — see `LICENSE`.
