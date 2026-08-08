# OnymInbox extraction notes

Extracted from `Sources/OnymIOS/Inbox/` into the local SPM package
`Packages/OnymInbox` (library `OnymInbox`, iOS 18, swift-tools 5.9).

## Files moved (11, all of Sources/OnymIOS/Inbox/)

- DecryptedInvitation.swift
- GroupStateVerifier.swift
- InboxFanoutInteractor.swift
- IncomingInvitationsInteractor.swift
- IncomingInvitationsRepository.swift
- IncomingMessageDispatcher.swift
- InvitationDecryptor.swift
- PendingInvitesFlow.swift
- PendingInvitesStore.swift
- PendingInvitesView.swift
- PendingVerificationStore.swift

## Imports added

- `IncomingMessageDispatcher.swift`: `import OnymChatsCore`
  (MessageRepository, ChatMessage, ChatMessagePayload,
  ChatReceiptPayload, ChatReceiptSending, NoopChatReceiptSender,
  MessageStatus). All other files already carried the imports they
  need (OnymTransport / OnymIdentity / OnymGroup / OnymChain /
  OnymPersistence / OnymDesign).

## Dependency trims

- **OnymFoundation trimmed** — no file in this package references any
  OnymFoundation symbol (each file carries its own local hex helper).
  All other listed dependencies are used:
  - OnymChatsCore: dispatcher chat-message/receipt branch
  - OnymGroup: payloads, GroupRepository, ChatGroup, IntroCapability,
    JoinRequestSender, IntroInboxPump, GroupCommitmentBuilder
  - OnymIdentity: IdentityRepository, IdentityID, IdentitySummary,
    InvitationEnvelopeDecrypting, IdentitiesProviding
  - OnymChain: ChainStateReading, SEPCommitmentEntry, SEPTier,
    SEPGroupType
  - OnymTransport: InboxTransport, TransportInboxID
  - OnymPersistence: InvitationStore, IncomingInvitationRecord,
    IncomingInvitationStatus
  - OnymDesign: OnymTokens, OnymAccent (PendingInvitesView)

## Public surface and its consumers

Consumers are the app target (`Sources/OnymIOS/*`) and the test target
(`Tests/OnymIOSTests/*`); no other package references these symbols
(hits in OnymGroup/OnymChatsCore/OnymPersistence are doc comments only).

| Symbol | Public members | Consumer |
|---|---|---|
| `DecryptedInvitation` | fields + explicit init | InvitationDecryptorTests constructs and reads fields |
| `GroupStateRefreshing` (protocol) | requirements (implicit) | dispatcher init param type; SpyGroupStateRefresher conformer in IncomingMessageDispatcherTests |
| `NoopGroupStateRefresher` | `init()`, both methods | *not referenced externally by name*, but it is the default-argument value of `IncomingMessageDispatcher`'s public init — default-arg expressions are emitted at the call site, so it must be public |
| `GroupStateVerifier` | init(identity:inboxTransport:groupRepository:store:refreshTimeoutSeconds:), start(), retry(groupIDHex:), deferVerification, handleRefreshRequest | OnymIOSApp wiring; GroupStateRefreshTests (incl. refreshTimeoutSeconds and direct defer/handle calls) |
| `InboxFanoutInteractor` | init (incl. debounceMilliseconds), run() | OnymIOSApp; InboxFanoutInteractorTests |
| `IncomingInvitationsInteractor` | explicit init(inboxTransport:repository:), run(inbox:ownerIdentityID:) | IncomingInvitationsInteractorTests, FakeInboxTransport doc |
| `IncomingInvitation` (typealias) | — | tests construct records; also appears in `snapshots` element type |
| `IncomingInvitationsRepository` | init(store:currentIdentityID:), recordIncoming, updateStatus, delete, removeForOwner, setCurrentIdentity, reload, snapshots | OnymIOSApp (reload/setCurrentIdentity/removeForOwner); repository + interactor + dispatcher tests (all mutators + snapshots) |
| `IncomingMessageDispatcher` | explicit public init (stored props stay internal), dispatch | OnymIOSApp; four dispatcher/fanout test files |
| `InvitationDecryptor` | explicit init(envelopeDecrypter:), decrypt | InvitationDecryptorTests |
| `PendingInvitesFlow` | init(...), start() | OnymIOSApp + AppDependencies construct/hold; ChatsView calls start(). All other members (pending, accept, dismiss, retry, badgeCount, …) stay internal — only used by in-package views |
| `PendingInvite` | fields public, **no public init** (only constructed in-package by the dispatcher) | IncomingMessageDispatcherTests reads fields via its PendingInvitesRecording spy |
| `PendingInvitesRecording` (protocol) | requirement (implicit) | dispatcher init param; SpyPendingInvites conformer in tests |
| `PendingInvitesStore` | init(), record (protocol witness), setCurrentIdentity, removeForOwner | OnymIOSApp; also default-arg value of dispatcher's public init. consume / consumeForMaterializedGroups / snapshots stay internal (only the in-package flow uses them) |
| `PendingInvitesToolbarButton` | explicit init(flow:), body | ChatsView |
| `PendingGroupVerification` (+ nested `Status`) | fields public, **no public init** (constructed only by GroupStateVerifier) | GroupStateRefreshTests reads snapshots/status |
| `PendingVerificationStore` | init(), contains(groupIDHex:), status(groupIDHex:), removeForOwner, setCurrentIdentity, snapshots | OnymIOSApp (setCurrentIdentity/removeForOwner + wiring); GroupStateRefreshTests (contains/status/snapshots). record / updateStatus / markUnreachableIfVerifying / resolveMaterialized stay internal (verifier-only) |

Internal (no external reference): `PendingInvitesView`,
`IncomingMessageDispatcher.TyrannyInvitationVerification`,
`ActiveSubscriptions` (private), all dispatcher stored properties.

## Decisions / ambiguities

- **Dispatcher memberwise-init trick replaced.** The old code kept
  `pendingInvites` etc. as `var` with inline defaults so the synthesized
  (internal) memberwise init retained defaulted parameters. A public
  type needs an explicit public init anyway, so the properties are now
  `let` and the defaults moved into the explicit init
  (`PendingInvitesStore()`, `NoopGroupStateRefresher()`,
  `NoopChatReceiptSender()`, `{ true }`). This preserves every existing
  call-site shape found in app + tests.
- **Assumption:** `NoopChatReceiptSender` (OnymChatsCore) must be
  `public` with a public `init()` since it is a default-argument value
  of this package's public dispatcher init. OnymChatsCore was being
  extracted concurrently and was not read — flag for integration.
- Tests currently live in `Tests/OnymIOSTests` (single app test
  target). Symbols referenced only by tests were made public on the
  assumption the test target will `import OnymInbox` after integration.
  If tests instead use `@testable import`, several of these
  (DecryptedInvitation's init, IncomingInvitationsInteractor, contains/
  status on PendingVerificationStore, GroupStateRefreshing, ...) could
  be demoted to internal.
- `InvitationDecryptor.swift` uses the module-local `IncomingInvitation`
  typealias without importing OnymPersistence — legal in Swift (member
  access does not require importing the defining module); no import
  added.
- `GroupStateVerifier` references `IntroInboxPump.inboxTag(from:)`
  (OnymGroup) — assumed public there.
