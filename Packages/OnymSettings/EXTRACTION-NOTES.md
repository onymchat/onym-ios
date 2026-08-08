# OnymSettings — extraction notes

Extracted from `Sources/OnymIOS/Settings/` (all 17 remaining files; `SettingsDesign.swift`
and `SettingsQRCode.swift` had already moved to OnymDesign).

## Files moved (17)

- AboutView.swift
- AnchorsPickerFlow.swift
- AnchorsView.swift
- BlossomRelaySettingsFlow.swift
- BlossomRelaySettingsView.swift
- ContractDetailView.swift
- DeployContractView.swift
- IdentityCarouselCard.swift
- NostrRelaySettingsFlow.swift
- NostrRelaySettingsView.swift
- PrivacyEncryptionView.swift
- RelayerSettingsFlow.swift
- RelayerSettingsView.swift
- RunYourOwnRelayerView.swift
- SelfHostGuideView.swift
- SettingsView.swift
- UseExistingContractView.swift

## Import changes

- `SettingsView.swift`: added `import OnymIdentityUI` (ShareKeyView) and
  `import OnymRecovery` (RecoveryPhraseBackupFlow / RecoveryPhraseBackupView).
- `IdentityCarouselCard.swift`: added `import OnymIdentityUI` (RemoveIdentitySheet).
- All other files already carried the correct cross-package imports
  (OnymDesign / OnymChain / OnymIdentity / OnymTransportNostr / OnymTransportBlossom /
  OnymChatsCore) from earlier extractions.

## Public surface (5 top-level types + 3 nested State structs)

Consumers referenced below live in `Sources/OnymIOS/` (app shell) and
`Tests/OnymIOSTests/` (flow unit tests).

### SettingsView (public struct)
- Consumer: `Sources/OnymIOS/RootView.swift` (constructs it in the Settings tab).
- Public members: explicit `public init(makeBackupFlow:makeRelayerSettingsFlow:
  makeNostrRelaySettingsFlow:makeBlossomRelaySettingsFlow:makeAnchorsPickerFlow:
  identitiesFlow:onClearAllMessages:)` (memberwise init is internal-only), `public var body`.
  Stored properties stay internal.

### AnchorsPickerFlow (public final class)
- Consumers: `Sources/OnymIOS/OnymIOSApp.swift` (init), `Sources/OnymIOS/AppDependencies.swift`
  (type in factory closure signature), `Tests/OnymIOSTests/AnchorsPickerFlowTests.swift`.
- Public members: `init(repository:)`, `state` (public read / private set), `start()`,
  `stop()`, `binding(for:)`, `availableReleases(for:)`, `hasExplicitSelection(for:)`,
  `hasAnyContracts(network:)`, `tappedVersion(key:releaseTag:)`, `tappedResetToDefault(key:)` —
  each used by the tests (start/stop/state/reads/intents) or the app (init).

### NostrRelaySettingsFlow / BlossomRelaySettingsFlow (public final classes)
- Consumers: OnymIOSApp.swift + AppDependencies.swift (init / factory type),
  `NostrRelaySettingsFlowTests.swift` / `BlossomRelaySettingsFlowTests.swift`.
- Public members: nested `State` struct with public `snapshot`, `customDraft`,
  `customDraftError` (tests read all three; State's memberwise init stays internal),
  `state`, `init(repository:)`, `start()`, `customDraftChanged(_:)`, `tappedAddCustom()`,
  `static validate(_:)`.
- Kept **internal**: `stop()`, `tappedRemove(url:)`, `tappedResetToDefault()` — only the
  in-package views call them.

### RelayerSettingsFlow (public final class)
- Consumers: OnymIOSApp.swift + AppDependencies.swift, `RelayerSettingsFlowTests.swift`.
- Public members: nested `State` (public snapshot/customDraft/customDraftError), `state`,
  `init(repository:)`, `start()`, `stop()`, `tappedAddKnown(_:)`, `customDraftChanged(_:)`,
  `tappedAddCustom()`, `tappedRemove(url:)`, `tappedSetPrimary(url:)`, `tappedStrategy(_:)`,
  `unconfiguredKnownList`, `isPrimary(_:)`, `static validate(_:)` — all exercised by the tests.
- Kept **internal**: `tappedRetryFetch()` (only RelayerSettingsView, in-package).

### Everything else stays internal
AboutView, AnchorsView, AnchorsNetworkView, AnchorsVersionView, BlossomRelaySettingsView,
ContractDetailView, DeployContractView, IdentityCarouselCard, RenameIdentitySheet,
RestoreIdentitySheet, NostrRelaySettingsView, PrivacyEncryptionView, RelayerSettingsView,
RunYourOwnRelayerView, SelfHostGuideView, SelfHostGuideStep, UseExistingContractView —
no references outside this package (verified by grep over Sources/, Tests/, and
Packages/ excluding OnymSettings).

## Dependency trims

Trimmed from the suggested list (no symbol from either module is referenced here):
- **OnymGroup** — `GovernanceType` turned out to live in OnymChain, not OnymGroup.
  (OnymGroup's CreateGroupView mentions `SettingsView` only in a doc comment.)
- **OnymTransport** — nothing referenced.

Kept: OnymChain, OnymIdentity, OnymIdentityUI, OnymRecovery, OnymTransportNostr,
OnymTransportBlossom, OnymChatsCore, OnymDesign.

## Ambiguities / decisions

- `IdentitiesFlow` and `IdentitySummary` resolve to the **OnymIdentity** package (already
  extracted) — not OnymIdentityUI.
- `ShareKeyView` and `RemoveIdentitySheet` currently sit in `Sources/OnymIOS/Identity/`;
  per instructions I trust they land in **OnymIdentityUI** (referenced by name, not read).
- `RecoveryPhraseBackupFlow` / `RecoveryPhraseBackupView` currently sit in
  `Sources/OnymIOS/Recovery/`; trusted to land in **OnymRecovery**.
- `AboutView`, `PrivacyEncryptionView`, and `AnchorsNetworkView` have **no consumers
  anywhere** (in- or out-of-package) — apparent dead code after the Settings redesign;
  moved as-is and kept internal rather than deleted.
- Flow `State` structs are public but their memberwise inits remain internal — no external
  code constructs them (tests only read fields of `flow.state`).
