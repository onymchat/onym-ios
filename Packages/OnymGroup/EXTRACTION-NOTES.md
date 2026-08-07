# OnymGroup extraction notes

Extracted from `Sources/OnymIOS/Group/` (all 39 remaining files; `OnymBrand.swift`
and `GovernanceMember.swift` had already been moved to OnymDesign / OnymChain by
sibling agents). Moved with plain `mv`; the now-empty `Sources/OnymIOS/Group/`
directory was removed.

## Files moved (39)

ApproveRequestsFlow, ApproveRequestsView, ChatGroup, CreateGroupFlow,
CreateGroupInteractor, CreateGroupView, CreateGroupViewHost, DeeplinkCapture,
GroupAvatarBroadcaster, GroupAvatarImage, GroupAvatarPayload,
GroupAvatarPickerButton, GroupCommitmentBuilder, GroupInvitationPayload,
GroupInviteOfferPayload, GroupNamePayload, GroupRepository,
GroupStateRefreshRequest, GroupStore, IntroCapability, IntroInboxPump,
IntroKeyEntry, IntroKeyStore, IntroRequest, IntroRequestStore, InviteIntroducer,
JoinFlow, JoinRequestApprover, JoinRequestPayload, JoinRequestSender, JoinView,
KeychainIntroKeyStore, MemberAnnouncementPayload, MemberProfile, PersistedGroup,
QRCodeScannerView, ShareInviteFlow, ShareInviteView, SwiftDataGroupStore (.swift)

## Dependencies

All six requested dependencies are used — **no trims**:

- OnymChain (GovernanceMember, SEPTier, SEPGroupType, RelayerRepository,
  ContractsRepository, GroupProofGenerator, SEPContractTransport, …)
- OnymIdentity (IdentityID, IdentityRepository, sealInvitation, …)
- OnymTransport (InboxTransport, TransportInboxID, PublishReceipt, …)
- OnymFoundation (StorageEncryption in PersistedGroup/SwiftDataGroupStore)
- OnymDesign (OnymTokens, OnymGroupAvatar, OnymAccent, OnymUIGovernance, … in views)
- OnymSDK from onym-sdk-swift (Common.* in GroupCommitmentBuilder)

Nothing here needs OnymTransportNostr — only the OnymTransport seam is used.

Import churn was minimal: sibling agents had already stamped most imports when
they moved the shared types. Changes made here:

- `ChatGroup.swift`: removed an unused `import OnymDesign` (only comments
  mention OnymDesign symbols).
- `GroupAvatarPickerButton.swift`: **bug fix** — `import OnymDesign` had been
  placed inside `#if canImport(ImagePlayground)` although OnymDesign symbols
  (OnymAccent, OnymGroupAvatar, OnymTokens) are used unconditionally; moved it
  out of the conditional block.

## Public surface (48 top-level symbols) and justifying consumers

Consumers checked in `Sources/`, `Tests/`, and other `Packages/` (all
non-comment references were in the app target and tests; hits inside
OnymIdentity/OnymDesign/OnymChain/OnymPersistence were doc comments only).

| Symbol | Consumer justifying `public` |
|---|---|
| ChatGroup (+ all stored props, groupIDData, explicit memberwise init) | IncomingMessageDispatcher, Chats*, many tests |
| MemberProfile (+ props, both inits), MemberProfileError | IncomingMessageDispatcher, ChatMembersView, MemberProfileTests |
| GroupRepository (init, insert, markPublished, markRead, delete, removeForOwner, setCurrentIdentity, reload, currentGroups, snapshots) | OnymIOSApp, Inbox/*, Chats/*, tests |
| GroupStore (protocol) | MessageStore, GroupRepositoryTests fakes |
| SwiftDataGroupStore (init, inMemory, protocol witnesses) | OnymIOSApp, SwiftDataMessageStore, tests |
| GroupInvitationPayload (props except peerBlsSecret, init, init(from:)) | IncomingMessageDispatcher, GroupStateVerifier, PendingInvitesStore, tests |
| GroupInviteOfferPayload (props, init, encode(to:), introCapability()) | IncomingMessageDispatcher, PendingInvitesStore, OnymIOSApp, tests |
| GroupNamePayload / GroupAvatarPayload (props except version, init) | IncomingMessageDispatcher, AppDependencies, tests |
| GroupStateRefreshRequest (props except version, both inits) | GroupStateVerifier, IncomingMessageDispatcher, tests |
| MemberAnnouncementPayload (+ AnnouncedMember, props except adminAlias, inits), MemberAnnouncementPayloadError | IncomingMessageDispatcher, tests |
| JoinRequestPayload (all props, both inits), JoinRequestPayloadError | IncomingMessageDispatcher, PendingInvitesFlow, tests |
| IntroCapability (props, id, inits, encode/encode(to:), toAppLink, toCustomSchemeLink, decode, fromLink, shareText), InvalidIntroCapability (+ description) | OnymIOSApp, ChatsView, PendingInvitesFlow, DeeplinkCapture/IntroCapability tests |
| DeeplinkCapture (introCapability(from:), introCapability(fromString:)) | OnymIOSApp, ChatsView, DeeplinkCaptureTests |
| IntroRequest (init; id, targetIntroPublicKey public) | JoinRequestApproverTests, IntroInboxPumpTests |
| IntroRequestStore (protocol), InMemoryIntroRequestStore (init, witnesses) | OnymIOSApp, PendingInvitesStore, tests |
| IntroKeyEntry (all props, init) | KeychainIntroKeyStoreTests, tests' InMemoryIntroKeyStore |
| IntroKeyStore (protocol) | OnymIOSApp, IdentityRepository wiring in app shell, tests |
| KeychainIntroKeyStore (init, serviceDefault, account, entryTTL, wipeAll, witnesses) | OnymIOSApp, KeychainIntroKeyStoreTests |
| InviteIntroducer (init, mint), IntroducerError | OnymIOSApp, ShareInviteFlow tests, InviteIntroducerTests |
| IntroInboxPump (init, run, static inboxTag) | OnymIOSApp, GroupStateVerifier, ChatReceiptSender, tests |
| JoinRequestSender (init, Outcome, send) | OnymIOSApp, PendingInvitesFlow, JoinFlowTests |
| JoinRequestApprover (init, PendingRequest + explicit init, ApproveOutcome, pending, start, pumpOnce, approve, decline), JoinRequestApproving | OnymIOSApp, IncomingMessageDispatcher, ApproveRequestsFlowTests (constructs PendingRequest), JoinRequestApproverTests |
| ApproveRequestsFlow (init, pending/lastError/lastSuccessMessage private(set), isInFlight, start, approve, decline, dismissError) | OnymIOSApp, ChatsView, AppDependencies, ApproveRequestsFlowTests |
| ApproveRequestsToolbarButton (init(flow:), body) | ChatsView |
| CreateGroupInteractor (init, create, randomCanonicalFr, isCanonicalFr) | OnymIOSApp, SendMessageInteractor, E2E/unit tests |
| CreateGroupProgress | appears in `CreateGroupInteractor.create`'s public signature (no direct external refs) |
| CreateGroupError (+ public errorDescription) | CreateGroupInteractorTests |
| CreateGroupFlow (init; name/governance/inviteeInput/onClose settable; invitees/generatedName/route/error private(set); inviteeError internal(set) — CreateGroupView clears it in-module; computed canAdvanceToStep2/effectiveName/createCTALabel/canCreate/canAddMoreInvitees/inviteeInputCleanedLength/inviteeInputIsValid; tapped* intents used by tests; static canonicalizeInviteKey) | OnymIOSApp, ChatsView, CreateGroupFlowTests, SettingsQRCodeTests |
| CreateGroupRoute | type of public `CreateGroupFlow.route`; read in tests |
| OnymInvitee (id, inboxPublicKey) | CreateGroupFlowTests reads `invitees[0].inboxPublicKey` (never constructed externally — no public init) |
| CreateGroupViewHost (init(makeFlow:makeShareInviteFlow:onClose:), body) | ChatsView |
| JoinFlow (init, State, state private(set), send) | OnymIOSApp, PendingInvitesFlow, JoinFlowTests |
| JoinView (init(flow:onClose:), body) | OnymIOSApp, ChatsView, PendingInvitesView |
| ShareInviteFlow (init, State, id, state private(set), mintFor) | OnymIOSApp, SearchView, Chats*, ShareInviteFlowTests |
| ShareInviteView (init(groupID:flow:onDone:), body) | ChatMembersView |
| GroupAvatarBroadcaster (init, setAvatar, setName) | OnymIOSApp |
| GroupAvatarPickerButton (init(imageData:size:accent:conceptText:), body) | ChatMembersView |
| GroupAvatarImage (dimension, maxBytes, both encode overloads) | ChatImageEncoder, GroupAvatarImageTests |
| GroupCommitmentBuilder (all six statics) | IncomingMessageDispatcher, tests |
| QRCodeScannerView (init(onScanned:onCancel:), body) | ChatsView |

## Kept internal (notable)

- `ApproveRequestsView`, `CreateGroupView` + step subviews, `OnymNavTitle` /
  `OnymPrimaryButton` / `OnymQuietButton` / `OnymSectionLabel`,
  `QRScannerRepresentable` / `QRScannerViewController`, `ImagePlaygroundPresenter`
  — only referenced inside this package (external mentions are doc comments).
- `PersistedGroup` (@Model) — only `SwiftDataGroupStore` touches it; the app's
  container is created inside the store.
- `GroupStateRefreshRequestError`, `GroupInviteOfferPayloadError`,
  `ActiveIntroSubscriptions`, `StoredIntroKey(sBlob)`, `ChatGroup.bytes(fromHex:)`,
  `JoinRequestApprover.stop()` / `decryptFailureCount()`, `ApproveRequestsFlow.stop()`,
  `CreateGroupFlow.submit()/tappedCreate()/createdGroup/progress/avatarImageData/
  invitationMessage` — no non-comment external references found.
- Wire-payload `version` properties stay internal where no consumer reads them
  (GroupAvatarPayload, GroupNamePayload, GroupStateRefreshRequest); the public
  inits still accept them. `GroupInvitationPayload.version` and
  `GroupInviteOfferPayload.version` are public (tests assert them).
- `MemberAnnouncementPayload.adminAlias`, `GroupInvitationPayload.peerBlsSecret`,
  `IntroRequest.payload/receivedAt`, `OnymInvitee.displayLabel` — set via public
  inits but never read outside the package.

## Judgment calls / ambiguities

1. **Explicit public memberwise inits** were added for `ChatGroup`,
   `GroupAvatarPayload`, `GroupNamePayload`, `IntroRequest`, and
   `JoinRequestApprover.PendingRequest` (synthesized memberwise inits are
   internal). Parameter order/defaults mirror the original memberwise shape.
2. **`CreateGroupProgress` is public without a direct external consumer**
   because it is a parameter type of the public `CreateGroupInteractor.create`.
3. **Observable flow state uses `public private(set)`** (`state`, `pending`,
   `route`, `error`, …) — consumers and tests only read these; intents mutate.
   `CreateGroupFlow.inviteeError` is `public internal(set)` because
   `CreateGroupView` (same module, different file) clears it.
4. Some "used" signals were name collisions in consumer files (e.g. `.store`,
   `.identity`); those members stayed internal after checking real call sites.
5. Access-control verification was grep-based (no build possible until the
   integration step); borderline members were resolved by reading the actual
   consumer call sites.

## Integration-step changes

- `Sources/OnymIOS/OnymBrandSEPBridge.swift` moved into this package
  (`Sources/OnymGroup/OnymBrandSEPBridge.swift`, kept internal): its only
  consumer is `CreateGroupFlow.sepGroupType` usage inside this package, and
  the package already depends on both OnymDesign and OnymChain. Layering is
  unchanged — OnymDesign still knows nothing about Chain types.
- `Package.swift`: `.iOS(.v18)` → `.iOS("18.0")` (`.v18` requires
  swift-tools-version 6.0; the string form matches the sibling packages).
- `IntroRequestStore` protocol: dropped a stray `public` on the `requests`
  requirement (invalid inside a protocol).
- Setter access widened from `private(set)` to `internal(set)` (public getters
  unchanged) so existing tests can seed state via `@testable import`:
  `CreateGroupFlow.invitees/route/error`,
  `ApproveRequestsFlow.lastError/lastSuccessMessage`.
