# OnymChatsUI — extraction notes

## Files moved (from `Sources/OnymIOS/Chats/` via plain `mv`)

- AlbumGridView.swift
- ChatBubbleCell.swift
- ChatEmptyStateView.swift
- ChatInputPanelView.swift
- ChatMembersView.swift
- ChatThreadView.swift
- ChatThreadViewController.swift
- ChatVoiceMessageView.swift
- ChatsFlow.swift
- ChatsView.swift

`Sources/OnymIOS/Chats/` was removed (empty after the move).

## Public surface (11 symbols/members, 3 types)

| Symbol | Why public | Consumer |
|---|---|---|
| `ChatsView` (struct) + explicit `public init` (15 params, matches old memberwise labels/order) + `public var body` | Constructed by the app's Chats tab | `Sources/OnymIOS/RootView.swift` |
| `ChatThreadView` (struct) + explicit `public init` (13 params incl. `scrollToMessageID: UUID? = nil`) + `public var body` | Constructed by the app's Search tab (`navigationDestination` for `MessageSearchResult`) | `Sources/OnymIOS/RootView.swift` |
| `ChatThreadView.debugTestImageData()` (`#if DEBUG`) | App's UI-test loopback harness builds its canned video poster from it | `Sources/OnymIOS/OnymIOSApp.swift` (`debugTestVideoEncoded`) |
| `ChatsFlow` (class) + `public init(repository:messages:)` | Constructed by app DI (`makeChatsFlow`) | `Sources/OnymIOS/OnymIOSApp.swift`, `Sources/OnymIOS/AppDependencies.swift` |
| `ChatsFlow.groups` (`public private(set)`) | Search tab's `groupNameForID` closure reads it | `Sources/OnymIOS/RootView.swift` |
| `ChatsFlow.start()` | Search tab's `startChats` closure calls it | `Sources/OnymIOS/RootView.swift` |

Everything else stays **internal** (or `private`, as it already was):
`ChatListItem`, `ChatMembersView`, `ChatThreadViewController`, `ChatBubbleCell`,
`ChatSenderDisplay`, `ChatReplyQuote`, `ChatInputPanelView`, `ChatVoiceMessageView`,
`VoiceWaveformView`, `AlbumGridView`, `ChatEmptyStateView`, `ChatsFlow.items/stop()/markRead/deleteChat`,
and all private helper views in ChatThreadView.swift.

Unit tests (`Tests/OnymIOSTests/ChatThreadViewControllerTests.swift`,
`ChatBubbleCellTests.swift`, `ChatInputPanelViewTests.swift`,
`ChatVoiceAttachmentTests.swift`) reference several of the internal types —
they should switch to `@testable import OnymChatsUI` when tests are re-homed
(the code already leans on this: ChatBubbleCell's test seams are deliberately
`internal` "so `@testable import` can reach it"). They did NOT drive any
public promotion.

## Dependency changes vs the prescribed list

- **Trimmed `OnymTransportBlossom`** — no file in this package references any
  Blossom symbol (blob loading is behind `ChatImageLoader`/`ChatVideoLoader`/
  `ChatVoiceLoader` in OnymChatsCore).
- **Added `OnymChain`** — `ChatsView.swift` has a `private extension
  SEPGroupType` (display label for the row subtitle) and `SEPGroupType` is
  defined in OnymChain; extending it requires a direct import.
- **Added `OnymIdentityUI`** — `ChatsView` uses `IdentityPickerMenu`, which a
  sibling extraction moved from `Sources/OnymIOS/Identity/` into the new
  `Packages/OnymIdentityUI` package (public there).

Kept as prescribed: OnymChatsCore, OnymInbox, OnymGroup, OnymIdentity, OnymDesign.

## Imports

The moved files already carried their package imports (`OnymDesign`,
`OnymChatsCore`, `OnymGroup`, `OnymIdentity`, `OnymInbox`, `OnymChain`) from a
prior pass; the only import added here is `OnymIdentityUI` in ChatsView.swift.

## Ambiguities / decisions

- `ChatsFlow.stop()` is currently uncalled anywhere (app included) — left
  internal rather than deleted.
- `ChatThreadView.videoThumbnail(for:)` is only used inside the file — left
  internal.
- Cross-package symbols this package consumes and expects to be public in
  their owners (verified public at extraction time): `ApproveRequestsFlow`/
  `ApproveRequestsToolbarButton`, `CreateGroupFlow`/`CreateGroupViewHost`,
  `ShareInviteFlow`/`ShareInviteView`, `JoinFlow`/`JoinView`,
  `QRCodeScannerView`, `DeeplinkCapture`, `IntroCapability`,
  `GroupAvatarPickerButton`, `MemberProfile`, `ChatGroup`, `GroupRepository`
  (OnymGroup); `MessageRepository`, `SendMessageInteractor`,
  `ChatReceiptSending`, `ReadReceiptsPreference`, `ChatVoiceRecorder`,
  loaders, attachments, `Blurhash`, `ChatMessage` + enums (OnymChatsCore);
  `IdentitiesFlow` (OnymIdentity); `IdentityPickerMenu` (OnymIdentityUI);
  `PendingInvitesFlow`/`PendingInvitesToolbarButton` (OnymInbox);
  `OnymTokens`/`OnymAccent`/`OnymGroupAvatar` (OnymDesign); `SEPGroupType`
  (OnymChain).
