# OnymFoundation extraction notes

Dependency-free leaf package (Foundation, CryptoKit, CommonCrypto, Security, os.log only).

## Files moved (from `Sources/OnymIOS/`, via plain `mv`)

| Original | New |
|---|---|
| `Identity/Bip39.swift` | `Sources/OnymFoundation/Bip39.swift` |
| `Identity/StellarStrKey.swift` | `Sources/OnymFoundation/StellarStrKey.swift` |
| `Identity/SecureRandom.swift` | `Sources/OnymFoundation/SecureRandom.swift` |
| `Chain/ContractsTrust.swift` | `Sources/OnymFoundation/ContractsTrust.swift` |
| `Persistence/StorageEncryption.swift` | `Sources/OnymFoundation/StorageEncryption.swift` |

All five were fully self-contained; nothing had to be left behind. No new
import statements were needed — every file already imported exactly the
system frameworks it uses, and there are no local package dependencies.

## Public surface (each symbol justified by an external consumer)

### `Bip39` (public enum)
- `generateMnemonic()` — `Sources/OnymIOS/Identity/IdentityRepository.swift`, `Tests/OnymIOSTests/SecureRandomTests.swift`
- `mnemonicFromEntropy(_:)` — `IdentityRepository.swift`
- `entropyFromMnemonic(_:)` — `IdentityRepository.swift`, `SecureRandomTests.swift`
- `isValidMnemonic(_:)` — `IdentityRepository.swift`, `SecureRandomTests.swift`
- `seedFromMnemonic(_:passphrase:)` — `IdentityRepository.swift`
- `deriveNostrKey(from:)` — `IdentityRepository.swift`
- `deriveBlsKey(from:)` — `IdentityRepository.swift`
- Kept **internal**: `suggestions(prefix:limit:)`, `isKnownWord(_:)` — no
  callers anywhere outside this package (grepped Sources/, Tests/, and
  other Packages/). If a mnemonic-entry UI later wants them, widen then.

### `StellarStrKey` (public enum)
- `encodeAccountID(_:)` — `IdentityRepository.swift`

### `SecureRandom` (public enum)
- `bytes(_:)` — `Sources/OnymIOS/Group/CreateGroupInteractor.swift`, `SecureRandomTests.swift`
- `data(_:)` — `CreateGroupInteractor.swift`, `SecureRandomTests.swift`
- `SecureRandomError` kept **internal**: thrown through public functions
  but never matched/constructed by name outside the package (legal in Swift;
  external callers see it as an opaque `Error`).

### `ContractsTrust` (public enum)
- `enforceSignatures` — `Tests/OnymIOSTests/ContractsTrustTests.swift`; also
  a default-argument value of the public `SignedAsset.verify`, which
  requires public visibility.
- `bundledPublicKey` kept **internal** — only referenced inside the package
  (from the stored-property initializer of `Ed25519DetachedSignatureVerifier.bundled`,
  which is not a default-argument context, so internal is legal).

### `Ed25519DetachedSignatureVerifier` (public struct)
- explicit `public init(publicKey:)` — constructed in `ContractsTrustTests.swift`
  (the implicit memberwise init would be internal).
- `static let bundled` public — used in `ContractsTrustTests.swift` (`verifier: .bundled`)
  and as the default-argument value of public `SignedAsset.verify`.
- `isValid(signature:for:)` public — `ContractsTrustTests.swift`.
- stored `publicKey` property kept **internal** — never read from outside.

### `SignedAssetVerificationError` (public enum)
- cases matched in `catch` clauses in `ContractsTrustTests.swift`.

### `SignedAsset` (public enum)
- `verify(assetData:assetURL:session:label:verifier:enforce:)` —
  `Sources/OnymIOS/Chain/ContractsManifestFetcher.swift`,
  `Chain/KnownRelayersFetcher.swift`, `Transport/Nostr/KnownNostrRelaysFetcher.swift`,
  `Transport/Blossom/KnownBlossomServersFetcher.swift`, `ContractsTrustTests.swift`
- `decodeSignature(_:)` — `ContractsTrustTests.swift`

### `StorageEncryption` (public enum)
- `encrypt(_ plaintext: Data)`, `encrypt(_ string: String)`, `decrypt(_:)`,
  `decryptString(_:)` — `Sources/OnymIOS/Group/SwiftDataGroupStore.swift`,
  `Persistence/SwiftDataInvitationStore.swift`, `Chats/SwiftDataMessageStore.swift`,
  `Tests/OnymIOSTests/StorageEncryptionTests.swift`
- `storageKey` — `StorageEncryptionTests.swift` (stability test)
- `StorageEncryptionError` kept **internal** — thrown but never matched by
  name outside the package.

Public symbol count: 8 public top-level types, 20 public members total.

## Dependency trims
The task listed no local dependencies for this package and none were
needed — the package has an empty `dependencies:` list (pure leaf).

## Decisions / caveats
- `ContractsTrust.loadBundledPublicKey()` reads
  `contracts-trust-pubkey.json` via `Bundle.main`. That resource stays in
  the app target; `Bundle.main` still resolves to the app bundle when the
  code runs inside the app, so behaviour is unchanged. If this package is
  ever used from a non-app host (e.g. unit tests of the package itself),
  the key will simply resolve to `nil` (which fails closed under
  enforcement — same as today's placeholder behaviour).
- Consumers (`IdentityRepository`, the four fetchers, the SwiftData
  stores, `CreateGroupInteractor`, and the three test files) will need
  `import OnymFoundation` at the later integration step; per instructions,
  files outside this package were not touched.
- Existing tests covering this code (`SecureRandomTests`,
  `ContractsTrustTests`, `StorageEncryptionTests`) remain in
  `Tests/OnymIOSTests/` — moving them was out of scope.
