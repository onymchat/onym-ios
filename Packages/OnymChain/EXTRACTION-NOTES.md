# OnymChain extraction notes

Extracted from `Sources/OnymIOS/Chain/` into the local SPM package
`Packages/OnymChain` (library `OnymChain`, iOS 18, swift-tools 5.9).

## Files moved (17, plain `mv`; `Sources/OnymIOS/Chain/` removed)

- AnchorSelection.swift
- AnchorSelectionStore.swift
- CachingChainStateReader.swift
- ChainStateReading.swift
- ContractEntry.swift
- ContractsManifestFetcher.swift
- ContractsRepository.swift
- GovernanceMember.swift
- GroupProofGenerator.swift
- KnownRelayersFetcher.swift
- NetworkPreference.swift
- RelayerEndpoint.swift
- RelayerRepository.swift
- RelayerSecrets.swift
- RelayerSelectionStore.swift
- SEPContractClient.swift
- SEPContractTypes.swift

Not moved (per instructions): `ContractsTrust.swift` (already in
OnymFoundation), `UITestFakes.swift` (stays at `Sources/OnymIOS/`).

## Dependencies

- `OnymFoundation` (local, `../OnymFoundation`) — `SignedAsset.verify`
  in `ContractsManifestFetcher.swift` and `KnownRelayersFetcher.swift`
  (H-3 detached-signature verification). Both files already carried
  `import OnymFoundation` from the earlier tier; no other file needed it.
- `OnymSDK` (`onym-sdk-swift` from 0.0.2) — `GroupProofGenerator.swift`
  (`Tyranny`/`Anarchy`/`OneOnOne` proof calls). Already had `import OnymSDK`.
- No dependency trims: both listed dependencies are genuinely used.

## Public surface (justifying consumer for each symbol)

Consumers are in `Sources/OnymIOS/**` and `Tests/OnymIOSTests/**` unless
noted. "DTO members public" = the stored properties listed are read
outside the package; everything else on the type stays internal.

### AnchorSelection.swift
- `AnchorSelectionKey` (public struct, public `network`, `type`, memberwise
  init) — constructed/read by CreateGroupInteractor, JoinRequestApprover,
  AnchorsView/AnchorsPickerFlow, UseExistingContractView, UITestFakes, tests.
- `AnchorBinding` (public struct; public `contractID`, `release` only) —
  `binding.contractID` (CreateGroupInteractor, JoinRequestApprover),
  `binding.release` (AnchorsView, ContractDetailView). `network`,
  `governanceType`, `key` and the memberwise init stay internal (only
  produced inside the package).

### AnchorSelectionStore.swift
- `AnchorSelectionStore` (public protocol) — conformed by UITestFakes and
  Tests/Support/InMemoryAnchorSelectionStore.
- `UserDefaultsAnchorSelectionStore` (public; public `init(defaults:)` +
  the four protocol witnesses) — OnymIOSApp, AnchorSelectionStoreTests.
- `JSONDecoder/JSONEncoder.iso8601()` extensions and `SelectionEntry`
  stay internal/private (no external use).

### CachingChainStateReader.swift
- `CachingChainStateReader` (public actor; public init with all tuning
  params; public `tyrannyCommitment`) — OnymIOSApp,
  CachingChainStateReaderTests (uses ttl/maxAttempts/baseRetryDelayMillis/now).

### ChainStateReading.swift
- `ChainStateReading` (public protocol) — IncomingMessageDispatcher holds
  the existential; test fakes conform.
- `SEPContractChainStateReader` (public; public init; witness public;
  stored members internal) — constructed in OnymIOSApp.
- `ChainReadError` (public enum) — matched in CachingChainStateReaderTests,
  IncomingMessageDispatcherTests, InboxFanoutInteractorTests.

### ContractEntry.swift
- `ContractNetwork`, `GovernanceType` (public enums, public `displayName`)
  — Settings views, LocalizationCatalogTests.
- `ContractEntry`, `ContractRelease`, `ContractsManifest` (public structs,
  public members, explicit public memberwise inits) — constructed in
  UITestFakes and many tests; members read in ContractDetailView,
  AnchorsView (`manifest.releases`), ContractsManifestDecodingTests
  (`manifest.version`). `ContractsManifest.empty` stays internal (no
  external use).

### ContractsManifestFetcher.swift
- `ContractsManifestFetcher` (public protocol) — UITestFakes,
  Tests/Support/FakeContractsManifestFetcher conform.
- `GitHubReleasesContractsManifestFetcher` (public; public `defaultURL`,
  `init(url:session:)`, `fetchLatest`, `decodeFiltering`) — OnymIOSApp,
  ContractsManifestDecodingTests (decodeFiltering + defaultURL),
  ContractsManifestFetcherTests, E2E tests.
- `ContractsManifestFetchError` (public enum) — matched in tests.
- `RawManifest` stays private.

### ContractsRepository.swift
- `ContractsState` (public struct; public `manifest`, `selections`,
  `empty`, `binding(for:)`, `availableReleases(for:)`,
  `hasAnyContracts(network:)`; init internal) — AnchorsPickerFlow + tests.
- `ContractsRepository` (public actor; public `init`, `start`, `refresh`,
  `select`, `clearSelection`, `currentState`, `binding(for:)`,
  `snapshots`) — OnymIOSApp, AnchorsPickerFlow, CreateGroupInteractor,
  JoinRequestApprover, tests. The actor-level `availableReleases(for:)`
  convenience stays internal (external callers use the ContractsState one).

### GovernanceMember.swift
- `GovernanceMember` (public struct, public members + init) — constructed
  and sorted in CreateGroupInteractor/JoinRequestApprover; `leafHash`
  read in GroupCommitmentBuilder; Codable payloads in Group/*.

### GroupProofGenerator.swift
- `GroupCreateProof` (public; public `proof`, `publicInputs`,
  `commitment`, `adminPubkeyCommitment`, init) — CreateGroupInteractor,
  test fakes construct it.
- `GroupProofGenerator` (public protocol) — existential in
  CreateGroupInteractor/JoinRequestApprover; test fakes conform.
- `GroupUpdateProof` (public; public `proof`, `publicInputs`,
  `commitmentNew`, init) — JoinRequestApprover; fake in
  JoinRequestApproverTests constructs it. `epochNew(epochOld:)` stays
  internal (no external use).
- `GroupProofUpdateInput`, `GroupProofCreateInput` (public; all members
  public + public inits) — constructed by interactors; test fakes read
  fields (`input.peerBlsSecretKey`, `input.adminIndex`, `input.members`,
  `input.epochOld`, `input.groupID`, ...).
- `GroupProofGeneratorError` (public enum) — matched in tests.
- `OnymGroupProofGenerator` (public; public `init()`, witnesses) —
  default arg in interactors, GroupProofGeneratorTests, E2E tests.

### KnownRelayersFetcher.swift
- `KnownRelayersFetcher` (public protocol) — UITestFakes,
  KnownNostrRelaysFetcher pattern, Tests/Support/FakeKnownRelayersFetcher.
- `GitHubReleasesKnownRelayersFetcher` (public; public `defaultURL`,
  init, `fetchLatest`) — OnymIOSApp, KnownRelayersFetcherTests.
- `KnownRelayersFetchError` (public enum) — KnownRelayersFetcherTests,
  RelayerRepositoryTests.

### NetworkPreference.swift
- `AppNetwork` (public enum; public `contractNetwork`, `sepNetwork`) —
  interactors bridge through both.
- `NetworkPreferenceProviding` (public protocol) — existential in
  interactors; test fakes conform.
- `UserDefaultsNetworkPreference` (public; public `storageKey`, init,
  `current()`) — `@AppStorage(UserDefaultsNetworkPreference.storageKey)`
  in SettingsView/AnchorsView; default arg in interactors.
- `StaticNetworkPreference` (public; explicit public `init(value:)`,
  public `current()`; `value` member internal) — tests.

### RelayerEndpoint.swift
- `RelayerEndpoint` (public; public `name`, `url`, `networks`, `id`,
  `customNetwork`, `custom(url:)`, `init(name:url:networks:)`,
  `init(from:)`, `encode(to:)`) — RelayerSettingsView/Flow,
  NostrRelayEndpoint mirror, UITestFakes, many tests. The Codable
  witnesses must be public because they are explicit witnesses on a
  public type.
- `KnownRelayersDocument` (public; public `version`, `relayers`) —
  decoded + fields asserted in RelayerEndpointSchemaTests.
- `RelayerStrategy` (public enum, public `displayName`) —
  RelayerSettingsView/Flow, LocalizationCatalogTests.
- `RelayerConfiguration` (public; public members incl.
  `hasUserInteracted`, `empty`, both inits, both `selectURL` overloads)
  — UITestFakes, RelayerConfigurationTests (seeded-RNG overload),
  RelayerSelectionStoreTests, RelayerRepositoryTests.

### RelayerRepository.swift
- `RelayerFetchStatus` (public enum) — no direct name reference outside,
  but it is the type of the public `RelayerState.fetchStatus`, which
  RelayerSettingsView switches over; must be public.
- `RelayerState` (public; public `configuration`, `knownList`,
  `fetchStatus`, `empty`; init internal) — RelayerSettingsView/Flow, tests.
- `RelayerRepository` (public actor; public `init`, `start`, `refresh`,
  `addEndpoint`, `removeEndpoint`, `setPrimary`, `setStrategy`,
  `currentState`, `selectURL`, `snapshots`) — OnymIOSApp,
  RelayerSettingsFlow, interactors, tests. `clearConfiguration()` stays
  internal (no external use).

### RelayerSecrets.swift
- `RelayerSecrets` (public enum, public `authToken`) — OnymIOSApp,
  CreateGroupInteractor, JoinRequestApprover.

### RelayerSelectionStore.swift
- `RelayerSelectionStore` (public protocol) — UITestFakes,
  Tests/Support/InMemoryRelayerSelectionStore conform.
- `UserDefaultsRelayerSelectionStore` (public; public `init(defaults:)` +
  four witnesses) — OnymIOSApp, RelayerSelectionStoreTests. PR #18
  legacy-migration helpers stay private.

### SEPContractClient.swift
- `SEPContractTransport` (public protocol) — UITestFakes and test fakes
  conform; interactors inject `any SEPContractTransport`.
- `URLSessionSEPContractTransport` (public; public init + `invoke`
  witness; stored members internal) — OnymIOSApp, interactors, tests.
- `SEPContractClient` (public; public init + the five invocation
  methods; stored members internal) — interactors,
  IncomingMessageDispatcher (`getCommitment`), SEPContractClientTests.

### SEPContractTypes.swift
- `SEPGroupType` (public enum) — very widely used (Group/Chats/Inbox,
  OnymBrandSEPBridge; OnymDesign only mentions it in a comment).
- `SEPTier` (public enum; public `depth`) — `tier.depth` in
  GroupCommitmentBuilder. `maxMembers` stays internal (no external use).
- `SEPNetwork` (public enum) — appears in public API (`AppNetwork.sepNetwork`,
  `SEPContractClient.init(network:)`); no external case references but the
  type must be public.
- `SEPContractInvocation` (public struct; public `function`, `payload`
  only) — external transport fakes receive it and read
  `invocation.function` / encode `invocation.payload` (UITestFakes,
  JoinRequestApproverTests). `contractID`/`contractType`/`network` and
  the memberwise init stay internal (only the client builds it).
- `TyrannyCreateGroupPayload`, `OneOnOneCreateGroupPayload`,
  `AnarchyCreateGroupPayload`, `TyrannyUpdateCommitmentPayload`
  (public structs with explicit public inits; stored members internal) —
  constructed by interactors/tests; nothing outside reads their fields
  (fakes decode the JSON instead).
- `GetCommitmentPayload` — internal (only `SEPContractClient` uses it).
- `SEPCommitmentEntry` (public; public `commitment`, `epoch`; public init
  with all five params; `timestamp`/`tier`/`active` members internal) —
  IncomingMessageDispatcher reads commitment/epoch; UITestFakes/tests
  construct with all labels.
- `SEPSubmissionResponse` (public; all members + init public) —
  interactors read `accepted`/`message`, tests read `transactionHash`,
  fakes construct it.
- `SEPError` (public enum; public `errorDescription` as explicit
  LocalizedError witness) — thrown/matched in UITestFakes and tests.

## Decisions on ambiguous points

- `import OnymFoundation` was already present in the two fetcher files
  (added when ContractsTrust moved in the earlier tier); verified those
  are the only two files touching `SignedAsset`/`ContractsTrust`, so no
  further import changes were needed. `import OnymSDK` likewise already
  present only in GroupProofGenerator.swift.
- Explicit Codable witnesses (`init(from:)`/`encode(to:)` on
  RelayerEndpoint, `init(from:)` on RelayerConfiguration,
  `errorDescription` on SEPError) were made public because Swift requires
  explicit witnesses of public-protocol requirements on public types to
  be public — not because a consumer calls them directly.
- Grep coverage: `Sources/`, `Tests/`, and all sibling `Packages/*`
  (OnymFoundation, OnymDesign, OnymIdentity, OnymTransport,
  OnymTransportBlossom). The only cross-package name hits were doc
  comments (ContractsRepository in OnymFoundation/ContractsTrust.swift,
  OnymGroupProofGenerator in OnymIdentity/IdentityRepository.swift,
  SEPGroupType in OnymDesign/OnymBrand.swift) — comments don't force
  public.
- Sibling agents were moving files concurrently, so external-reference
  results reflect the tree at extraction time; if another tier later
  moves a consumer that used an internal member (e.g. `AnchorBinding.network`,
  `SEPTier.maxMembers`, `RelayerRepository.clearConfiguration`), widen
  that one member rather than the whole type.
- Syntax verified with `swiftc -parse` on the package sources (no
  project build attempted, per instructions).
