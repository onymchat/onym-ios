# OnymIdentity extraction notes

Extracted from the `OnymIOS` app target into a local SPM package. The four
SwiftUI view files (`IdentitiesView.swift`, `IdentityDetailView.swift`,
`ShareKeyView.swift`, `IdentityPickerMenu.swift`) stayed in
`Sources/OnymIOS/Identity/` for a later UI package.

## Files moved (13)

- IdentityRepository.swift (also defines SelectedIdentityStore, ProtectedDataAvailability, InstallMarker)
- IdentityKeychainStore.swift (also defines StoredSnapshot)
- IdentitiesFlow.swift
- Identity.swift
- IdentitySummary.swift
- IdentityID.swift
- IdentityError.swift
- IdentitiesProviding.swift
- InvitationEnvelopeDecrypting.swift (also defines InvitationDecryptError)
- InvitationEnvelopeSealing.swift (also defines InvitationSealError)
- SealedEnvelope.swift
- DecryptedEnvelope.swift
- OnymNostrSigner.swift (also defines OnymNostrSignerProvider)

## Dependencies

- OnymFoundation — Bip39, StellarStrKey (IdentityRepository derivation paths).
- OnymTransport — NostrSigner / NostrEphemeralSignerProvider / NostrSignerError
  (OnymNostrSigner conformances).
- OnymSDK (onym-sdk-swift) — `Common.nostrDerivePublicKey`, `Common.publicKey`,
  `Common.nostrSignEventId` (IdentityRepository, OnymNostrSigner).

No dependency trims — all three listed dependencies are used. All import
statements were already present in the moved files (a previous extraction pass
added them); no new imports were needed.

## Public surface and justifying consumers

Consumers are cited as repo-relative paths. "Tests" = `Tests/OnymIOSTests/`.

### IdentityRepository (public actor)
- `shared` — Sources/OnymIOS/OnymIOSApp.swift and others (`IdentityRepository.shared`)
- `init(keychain:selectionStore:installMarker:protectedData:)` — tests construct with
  custom keychain/selection/marker/protectedData (IdentityRepositoryTests,
  IdentityRepositoryFreshInstallTests, …). All four parameter types and the
  default-argument statics (`IdentityKeychainStore()`, `.userDefaults` x2,
  `.uiApplication`) must therefore be public (default args inline at call site).
- `bootstrap()`, `add(name:mnemonic:)`, `select(_:)`, `remove(_:)`, `rename(_:newName:)`,
  `restore(mnemonic:)`, `wipe()` — app flows + tests (widely used)
- `currentIdentity()`, `currentSelectedID()`, `currentIdentityName()`,
  `currentIdentities()` — Group/Chats/Inbox interactors + tests
- `blsSecretKey()` — Sources/OnymIOS/Group/{CreateGroupInteractor,JoinRequestSender,JoinRequestApprover}.swift
  (SECRET-BEARING: pre-existing consumers; doc comment about not retaining the
  bytes preserved verbatim)
- `snapshots`, `identitiesStream`, `currentIdentityID`, `identityRemoved` —
  Settings flows, GroupRepository, IdentitiesFlow consumers, tests
- `decryptInvitation(envelopeBytes:asIdentity:)`, `decryptInvitationWithSender(...)` —
  witnesses of public `InvitationEnvelopeDecrypting`; called via existential in
  Sources/OnymIOS/Inbox/IncomingMessageDispatcher.swift
- `sealInvitation(payload:to:)` — Sources/OnymIOS/Group/*, Chats/SendMessageInteractor.swift,
  Inbox/GroupStateVerifier.swift, ChatReceiptSender.swift (called directly on the
  repository, not through the protocol)
- `static decryptSealedEnvelope(envelopeBytes:recipientX25519PrivateKey:)` —
  Sources/OnymIOS/Group/JoinRequestApprover.swift:697
- Kept INTERNAL: `static decryptSealedEnvelope(envelope:...)`,
  `static decryptSealedEnvelopeWithSender(...)`, `static fallbackName(forNewSlot:)`
  (no external references)

### SelectedIdentityStore (public struct)
- `static inMemory(initial:)` — Tests/IdentityRepositoryMultiIdentityTests.swift:161
  and many `selectionStore: .inMemory()` call sites
- `static userDefaults` — public because it is the repository init's default argument
- `load`/`save` stored closures kept internal (no external reads)

### ProtectedDataAvailability (public struct)
- `init(isAvailable:)` — Tests/IdentityRepositoryFreshInstallTests.swift:98,136
  (explicit public init added; memberwise was internal)
- `static uiApplication` — public as the repository init default argument
- `static always` kept internal (no external references); `isAvailable` property internal

### InstallMarker (public struct)
- `static inMemory(initiallySet:)` — Tests/IdentityRepositoryFreshInstallTests.swift
- `exists` — Tests/IdentityRepositoryFreshInstallTests.swift (`marker.exists()`)
- `static userDefaults` — public as the repository init default argument
- `set` stored closure kept internal (no external calls)

### IdentityKeychainStore (public struct)
- `init(testNamespace:)` — Sources/OnymIOS/OnymIOSApp.swift:741 (uitests reset hook) + many tests
- `list()`, `read(_:)`, `write(_:_:)`, `wipe(_:)`, `wipeAll()` — Tests/IdentityKeychainStoreTests.swift and other test setups
- `quarantineAll()`, `listQuarantined()` — Tests (fresh-install / verifier tests)
- `static servicePrefix` / `account` / `quarantineServicePrefix` and `testNamespace`
  kept internal (no external references)

### StoredSnapshot (public struct)
- Constructed in Tests/IdentityKeychainStoreTests.swift → explicit public init
  (memberwise inits are internal)
- `entropy`, `nostrSecretKey`, `blsSecretKey` public — read by
  Tests/IdentityRepositoryTests.swift:53-55. SECRET-BEARING: publicised only
  because these existing consumers already read them; all secret-handling doc
  comments preserved. `name` kept internal (no external reads).

### IdentitiesFlow (public @Observable class)
- `init(repository:)` — OnymIOSApp.swift:285, Tests/IdentitiesFlowTests.swift
- Public members (all referenced from the retained Identity views under
  Sources/OnymIOS/Identity/ + Settings/IdentityCarouselCard.swift + tests):
  `identities`, `currentID`, `pendingName`, `pendingMnemonic`, `addError`,
  `pendingRemoval`, `pendingRemovalConfirmText`, `start()`, `select(_:)`,
  `rename(_:newName:)`, `submitAdd()`, `cancelAdd()`, `startRemoval(of:)`,
  `canConfirmRemoval`, `confirmRemoval()`, `cancelRemoval()`, `blsPrefix(of:)`
- `stop()` — public: called from Tests/OnymIOSTests/IdentitiesFlowTests.swift:25
  (`flow?.stop()` in tearDown)

### Identity (public struct)
- Never constructed outside the package → NO public init (memberwise stays internal)
- All seven `let` fields public — each read externally: `nostrPublicKey`,
  `blsPublicKey`, `stellarPublicKey`, `stellarAccountID`, `inboxPublicKey`,
  `inboxTag`, `recoveryPhrase` (recoveryPhrase is display-only backup UX;
  Identity carries no secret keys — see its doc comment)

### IdentitySummary (public struct)
- Constructed in Tests/IncomingMessageDispatcherTests.swift:954,1003 → explicit public init
- All fields public (id/name/blsPublicKey/inboxPublicKey used by views + flows;
  sendingPublicKey by the chat dispatcher)

### IdentityID (public struct)
- `init(_ UUID)` — tests (`IdentityID()`); `init?(_ String)` —
  Sources/OnymIOS/Group/SwiftDataGroupStore.swift:193, KeychainIntroKeyStore.swift, …
- `rawValue` — Settings/IdentityCarouselCard.swift (`.rawValue.uuidString`)
- `description`, `init(from:)`, `encode(to:)` — public as hand-written witnesses of
  public protocol conformances (CustomStringConvertible, Codable)

### IdentityError (public enum)
- Case matching in Tests/IdentityRepositoryTests.swift:148,264; also surfaced
  through IdentitiesFlow error handling. `errorDescription` public (LocalizedError witness).

### IdentitiesProviding (public protocol)
- External conformer Tests/ (StubIdentities); existential
  `any IdentitiesProviding` in Sources/OnymIOS (inbox interactors)

### InvitationEnvelopeDecrypting (public protocol) + InvitationDecryptError (public enum)
- External conformer Tests/Support/FakeInvitationEnvelopeDecrypter.swift;
  existential `any InvitationEnvelopeDecrypting` in
  Sources/OnymIOS/Inbox/IncomingMessageDispatcher.swift
- The protocol-extension default `decryptInvitationWithSender` is public so
  external conformers inherit it
- Error cases matched in Tests/IdentityRepositoryInvitationDecryptTests.swift
  and thrown by the test fake

### SealedEnvelope (public struct)
- Constructed in Tests/{SealedEnvelopeTests,IdentityRepositoryInvitationDecryptTests,
  Support/TestInvitationEncryptor}.swift → explicit public init
- All fields public (tests inspect decoded envelopes). Note: its doc comment
  still says "Internal to the Identity layer" — that remains the intent for
  production code; it is public solely for the wire-format tests until the
  test target is split per-package.

### DecryptedEnvelope (public struct)
- Fields read in Sources/OnymIOS/Inbox/IncomingMessageDispatcher.swift
  (`.plaintext`, `.senderEd25519PublicKey`); constructed in
  Tests/Support/FakeInvitationEnvelopeDecrypter.swift → explicit public init

### OnymNostrSigner / OnymNostrSignerProvider (public structs)
- `OnymNostrSigner(secretKey:)`, `.ephemeral()`, `publicKey()`, `signEventID(_:)` —
  Tests/{OnymNostrSignerTests,NostrEventTests,NostrInboxTransportTests,
  NostrMessageTransportTests,ChatImagePipelineTests}.swift; publicKey/signEventID
  are also witnesses of the public OnymTransport.NostrSigner protocol
- `secretKey` property public — SECRET-BEARING; publicised only because
  Tests/OnymNostrSignerTests.swift:100,106 already reads it directly
- `OnymNostrSignerProvider` — OnymIOSApp.swift, Chats/SendMessageInteractor.swift;
  explicit `public init()` added (constructed externally)

## Kept internal (whole declarations)

- `InvitationEnvelopeSealing` protocol — zero external references by name; every
  consumer calls `sealInvitation` directly on `IdentityRepository`. The
  conformance is retained internally. (Its `InvitationSealError` IS public —
  Tests/IdentityRepositorySealInvitationTests.swift matches its cases.)
- `StoredSnapshot.name`, `InstallMarker.set`, `SelectedIdentityStore.load/save`,
  `ProtectedDataAvailability.isAvailable`/`.always`,
  `IdentityKeychainStore` statics, repository's pre-decoded decrypt statics and
  `fallbackName`.

## Ambiguities / decisions

- Tests currently live in the app test target (`Tests/OnymIOSTests`), so
  test-only usage counts as external and drives a fair amount of the public
  surface (StoredSnapshot, SealedEnvelope init, keychain quarantine API,
  OnymNostrSigner.secretKey, the repository injection init). If tests are later
  moved into this package's own test target, those can be tightened back to
  internal — flagged inline above as SECRET-BEARING where relevant.
- `InvitationEnvelopeSealing.swift` imports OnymTransport but uses no symbol
  from it (only doc-comment references to `InboxTransport`). Left as found to
  minimise diff; safe to drop later.
- UIKit import in IdentityRepository (`UIApplication.isProtectedDataAvailable`)
  is fine — the package is iOS-only (platforms: [.iOS(.v18)]).
