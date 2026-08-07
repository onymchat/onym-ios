# OnymDesign — extraction notes

Extracted from the OnymIOS app target as a dependency-free leaf SPM package
(swift-tools-version 5.9, iOS 18, no package dependencies).

## Files moved (plain `mv`, no git)

| From (Sources/OnymIOS/) | To (Sources/OnymDesign/) |
|---|---|
| Group/OnymBrand.swift | OnymBrand.swift |
| Settings/SettingsDesign.swift | SettingsDesign.swift |
| Settings/SettingsQRCode.swift | SettingsQRCode.swift |

No new imports were needed inside the moved files: they only use SwiftUI,
UIKit, and CoreImage.CIFilterBuiltins (system frameworks), all already
imported.

## Chain decoupling (special instruction)

`OnymUIGovernance.sepGroupType` referenced `SEPGroupType`
(Sources/OnymIOS/Chain/SEPContractTypes.swift). The computed property was
removed from the package and recreated as an app-target extension in the new
file **Sources/OnymIOS/OnymBrandSEPBridge.swift** (`import OnymDesign`).
`OnymUIGovernance` itself stays in the package (its cases are public, so the
bridge can switch over them). If Chain is later extracted into its own
package, the bridge file will need that package's import added — flagged for
the integration step.

## Public surface (23 top-level symbols)

Every `public` below is justified by a consumer outside Packages/OnymDesign
(grepped Sources/, Tests/, and other Packages/):

- `OnymTokens` — ~30 files (ChatsView, SettingsView, CreateGroupView, …).
  All 12 tokens public: bg, surface, surface2, surface3, text, text2, text3,
  hairline, hairlineStrong, green, red, onAccent — each individually grepped
  and externally used.
- `Color.dynamic(light:dark:)` — IdentityDetailView.swift:110-113.
- `OnymAccent` — ChatBubbleCell, ChatThreadViewController, ChatInputPanelView,
  AboutView, tests. Public members: `id` (Identifiable witness), `color`
  (66+ uses), `forSender(blsPubkeyHex:)` (chat + OnymAccentSenderColorTests);
  `allCases`/`rawValue`/cases come with the public enum
  (OnymAccentSenderColorTests uses `allCases`).
- `OnymMark` — AboutView, SettingsView, ContractDetailView, IdentitiesView,
  IdentityDetailView. Public init exposes all five knobs (size, color,
  strokeRatio, spinning, fillOpacity); external callers use size/color/spinning
  only, but splitting the init into public-minimal + internal-full creates
  in-module overload ambiguity at existing call sites, so one init was kept.
- `OnymUIGovernance` — CreateGroupFlow, CreateGroupView, ChatsView.
  Public: `id`, `label` (CreateGroupView:367,1077), `isAvailable`
  (CreateGroupFlow:112,285); cases switched on in CreateGroupView:415-431.
  `sub`, `oneLine`, `tooltip` kept **internal** (no external consumer).
- `OnymGovIcon` — CreateGroupView:287,365,1075. Public
  init(type:accent:size:dimmed:) — all four labels appear at call sites.
- `OnymGroupAvatar` — GroupAvatarPickerButton, ChatMembersView,
  CreateGroupView, ChatsView. Public
  init(size:accent:ringPulse:spinning:brand:imageData:) — all used externally.
- `SettingsTile` — 11 files. Public: purple, blue, indigo, orange, green,
  gray, red, amber. **`teal` kept internal** (no consumer anywhere).
- `SettingsIconTile` — 9 files. Public init(symbol:bg:) only — `size` and
  `weight` are never passed externally; they stay internal defaults.
- `SettingsContentTile` — AnchorsView, UseExistingContractView,
  ContractDetailView, PrivacyEncryptionView. Public init(bg:content:) —
  `size` never passed externally.
- `SettingsSectionLabel` — 11 files, always the text-only form. Only the
  `Trailing == EmptyView` convenience init is public; the trailing-content
  designated init stays internal (no external consumer).
- `SettingsFootnote` — 14 files. Public init(_:).
- `SettingsLargeTitle` — SettingsView etc. Public init(_:).
- `SettingsCard` — 12 files. Public init(content:).
- `SwipeToDeleteRow` — Nostr/Relayer/BlossomRelaySettingsView. Public
  init(accessibilityID:onDelete:content:) — `deleteLabel` never passed
  externally, stays internal default.
- `SettingsRowDivider` — RelayerSettingsView:278, IdentityDetailView:184.
  Public init(inset:).
- `SettingsRow` — 11 files. Full public init (title, titleColor, titleMono,
  subtitle, subtitleMono, subtitleLineLimit, hasChevron, inset, last, onTap,
  tile, right — every label appears at external call sites) plus the public
  `Right == EmptyView` convenience init (AboutView:27 uses it).
- `SettingsChip` — UseExistingContractView, RelayerSettingsView. Explicit
  public init(text:fg:bg:) (memberwise would be internal).
- `SettingsTextButton` — IdentityDetailView:187 (uses `foreground:`). Public
  init(title:systemImage:foreground:action:).
- `SettingsPrimaryButton` — UseExistingContractView (generic
  init(disabled:action:label:)), ContractDetailView (Text convenience
  init(_:disabled:action:)). Both inits public.
- `IdentityRingTile` — ShareKeyView:30, PrivacyEncryptionView:71,
  IdentitiesView:104. Public init(active:size:).
- `SettingsQRCode` — ShareKeyView, IdentityCarouselCard, IdentityDetailView,
  ShareInviteView, tests. Public init(value:size:).
- `settingsInviteURL(blsPublicKey:)` — ShareKeyView, IdentityCarouselCard,
  IdentityDetailView, SettingsQRCodeTests.

## Kept internal / private

- `SettingsStepIndicator` — zero consumers outside the package (appears
  unused everywhere right now); left internal, not deleted.
- `PulseModifier` — already `private`.
- `OnymUIGovernance.sub/.oneLine/.tooltip` — no consumers (CreateGroupView's
  `step.sub` at line 872 is `CreateGroupCreatingStep`, a different type);
  currently dead code, left internal rather than deleted.
- `SettingsTile.teal`, `SettingsIconTile.weight/.size`,
  `SettingsContentTile.size`, `SwipeToDeleteRow.deleteLabel`,
  `SettingsSectionLabel` trailing variant — internal (no external use).

## Dependency trims

The task allowed local dependencies but none were needed: the package is a
pure SwiftUI/UIKit/CoreImage leaf. The only would-be dependency (Chain, for
`SEPGroupType`) was severed via the bridge file per instructions.

## Integration-step reminders (not done here, per constraints)

- Consumers listed above need `import OnymDesign` added.
- project.yml must gain the package reference; regenerate the xcodeproj.
- Tests (OnymAccentSenderColorTests, SettingsQRCodeTests) exercise package
  API from the app test target; they work via `import OnymDesign` (all
  symbols they touch are public), or could move into a package test target
  later.
- If Chain becomes a package, add its import to
  Sources/OnymIOS/OnymBrandSEPBridge.swift.
