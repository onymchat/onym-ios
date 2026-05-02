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
├── Sources/OnymIOS/
│   ├── OnymIOSApp.swift                     ← @main, holds the repo
│   ├── IdentityBootstrapView.swift          ← drains snapshots into @State
│   └── Identity/
│       ├── Identity.swift                   ← Sendable value type the views see
│       ├── IdentityRepository.swift         ← actor + AsyncStream snapshots
│       ├── KeychainStore.swift              ← single-blob Codable in Keychain
│       ├── IdentityError.swift              ← single error type
│       ├── Bip39.swift                      ← BIP39 wordlist + PBKDF2 + HKDF
│       └── StellarStrKey.swift              ← Ed25519 → G... account ID encoder
├── Tests/OnymIOSTests/
│   ├── SmokeTests.swift                     ← OnymSDK wiring sanity check
│   └── IdentityRepositoryTests.swift        ← real-Keychain integration tests
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

## Versioning

This repo tracks `OnymSDK` at `from: "0.0.1"`. Until the SDK hits
1.0, breaking changes can land in any minor bump — pin to a specific
version (`exact: "X.Y.Z"`) if reproducibility matters more than
auto-upgrade.

## License

MIT — see `LICENSE`.
