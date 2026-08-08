# OnymIdentityUI — extraction notes

## Files moved (from `Sources/OnymIOS/Identity/` → `Sources/OnymIdentityUI/`)

- `IdentitiesView.swift`
- `IdentityDetailView.swift`
- `ShareKeyView.swift`
- `IdentityPickerMenu.swift`

`Sources/OnymIOS/Identity/` was left empty by the move and removed with `rmdir`.

## Public surface (3 types, 9 public declarations)

| Symbol | Public members | Justifying consumer |
|---|---|---|
| `ShareKeyView` | struct, `init(identity:blsPrefix:)`, `body` | `Sources/OnymIOS/Settings/SettingsView.swift:188` |
| `RemoveIdentitySheet` | struct, `init(flow:summary:)`, `body` | `Sources/OnymIOS/Settings/IdentityCarouselCard.swift:90` |
| `IdentityPickerMenu` | struct, `init(flow:)`, `body` | `Sources/OnymIOS/Chats/ChatsView.swift:57` |

Explicit public inits were added to all three (memberwise inits are internal).
`body` is public on each because a public struct's `View` conformance requires it.

## Kept internal

- `IdentitiesView` — no references anywhere outside this package (grepped
  `Sources/`, `Tests/`, and all other `Packages/`). Settings now appears to use
  `IdentityCarouselCard` instead of pushing this screen; if integration later
  needs it, it only requires `public` + a public `init(flow:)` + public `body`.
- `IdentityDetailView` — only instantiated from `IdentitiesView` within this package.
- `AddIdentitySheet`, `EditableIdentityName` — already `private`.
- `IdentityDetailView.maxIdentityNameLength` — `fileprivate`, unchanged.

## Dependencies

Both listed dependencies are used — no trims:

- `OnymIdentity` — `IdentitiesFlow`, `IdentitySummary` (all four files).
- `OnymDesign` — `OnymTokens`, `OnymAccent`, `OnymMark`, `SettingsRow`,
  `SettingsCard`, `SettingsLargeTitle`, `SettingsFootnote`, `SettingsSectionLabel`,
  `SettingsIconTile`, `SettingsTile`, `SettingsQRCode`, `SettingsRowDivider`,
  `SettingsTextButton`, `IdentityRingTile`, `settingsInviteURL`,
  `Color.dynamic(light:dark:)` (three of four files; `IdentityPickerMenu` uses
  only SwiftUI + OnymIdentity).

## Import changes

None needed — all four files already carried `import OnymDesign` /
`import OnymIdentity` alongside `import SwiftUI` before the move (a prior
extraction pass evidently added them when those packages were split out).

## Ambiguities / decisions

- `IdentitiesView` being externally unreferenced was unexpected for the
  package's headline screen; verified by repo-wide grep (including concurrent
  agents' `Packages/` trees at extraction time) and kept internal per the
  minimal-surface rule. A consumer moved *after* my grep could invalidate
  this — integration should re-check.
- `Tests/OnymIOSUITests/IdentityManagementUITests.swift` mentions
  `RemoveIdentitySheet` only in a comment; UI tests are black-box and impose
  no access-control requirement. The public justification is
  `IdentityCarouselCard.swift`.
