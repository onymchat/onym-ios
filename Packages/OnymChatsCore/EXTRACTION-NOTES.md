# OnymChatsCore — extraction notes

Chats DOMAIN half of `Sources/OnymIOS/Chats/`: models, payloads, repositories,
stores, media encode/crypto/load pipeline, outbox, receipts, interactor.
The view layer (AlbumGridView, ChatBubbleCell, ChatEmptyStateView,
ChatInputPanelView, ChatMembersView, ChatThreadView, ChatThreadViewController,
ChatVoiceMessageView, ChatsFlow, ChatsView) stays in `Sources/OnymIOS/Chats/`
for a later OnymChatsUI package. None of the 23 listed files turned out to be
views; all were moved.

## Files moved (23, `Sources/OnymIOS/Chats/` → `Sources/OnymChatsCore/`)

Blurhash, ChatImageAttachment, ChatImageCrypto, ChatImageEncoder,
ChatImageLoader, ChatMediaAttachment, ChatMessage, ChatMessagePayload,
ChatOutbox, ChatReceiptPayload, ChatReceiptSender, ChatVideoAttachment,
ChatVideoEncoder, ChatVideoLoader, ChatVoiceAttachment, ChatVoiceEncoder,
ChatVoiceLoader, ChatVoiceRecorder, MessageRepository, MessageStore,
PersistedMessage, SendMessageInteractor, SwiftDataMessageStore (.swift).

## Dependencies (Package.swift) — no trims

All six listed local packages are genuinely used:

- **OnymGroup** — `GroupRepository`, `ChatGroup` (SendMessageInteractor roster/fan-out)
- **OnymIdentity** — `IdentityID`, `IdentityRepository`, `OnymNostrSignerProvider`
  (default `URLSessionBlossomClient` signer in SendMessageInteractor's init)
- **OnymTransport** — `InboxTransport`, `TransportInboxID`, `TransportError`
- **OnymTransportBlossom** — `BlossomClient`, `URLSessionBlossomClient`, `BlossomError`
- **OnymChain** — `SEPGroupType` (ChatMessage, ChatMessageVariant, SwiftDataMessageStore)
- **OnymFoundation** — `StorageEncryption` (SwiftDataMessageStore at-rest crypto)

Note: `import OnymTransport` in ChatMessagePayload.swift / ChatReceiptPayload.swift
and `import OnymFoundation` in PersistedMessage.swift are technically unused in
code (doc-comment references only); left in place, harmless.

## Public surface and justifying consumers

External consumers found (concurrent agents had already moved some):
`Packages/OnymInbox/…/IncomingMessageDispatcher.swift` (dispatcher),
`Sources/OnymIOS/OnymIOSApp.swift`, `Sources/OnymIOS/AppDependencies.swift`,
`Sources/OnymIOS/UITestFakes.swift`, the Chats/Search/Settings views left in
`Sources/OnymIOS/`, and `Tests/OnymIOSTests/*` (payload, pipeline, repository,
store, interactor, dispatcher tests).

Public top-level types (31; nested public types in parentheses):

| Symbol | Justifying consumer(s) |
|---|---|
| `Blurhash` (.encode, .decode) | ChatBubbleCell, AlbumGridView (decode); ChatImagePipelineTests (encode) |
| `ChatImageAttachment` (+ public init; all fields public except `byteSize`) | dispatcher (payload → ChatMessage), ChatBubbleCell/AlbumGridView (width/height/blurhash/sha256), attachment tests (construct + assert fields) |
| `ChatImageCrypto` (.seal, .open, .sha256Hex; `Sealed` with public key/blob/sha256Hex; `CryptoError`) | ChatImagePipelineTests, SendMessageInteractorTests |
| `ChatImageEncoder` (.encode ×2, maxEdge, maxBytes; `Encoded`, fields public, no public init — only ever produced by encode) | ChatImagePipelineTests, UITestFakes (poster via encode) |
| `ChatImageLoader` (init, image(for:)) | OnymIOSApp, ChatBubbleCell/ChatThreadView, pipeline tests. `prime` stays internal (only SendMessageInteractor uses it) |
| `ChatMediaSource` | ChatThreadView (album picking) |
| `ChatMediaAttachment` (thumbnail, isVideo, blobShas, public Codable init/encode) | AlbumGridView, SendMessageInteractorTests (blobShas). `asImage`/`asVideo` internal (interactor-only) |
| `ChatMessage` (public init, all stored props, `media`, `chatListPreview`) | dispatcher constructs; views render everything; tests |
| `MessageDirection`, `MessageStatus`, `SendFailureReason` (.explanation) | dispatcher, views, tests. `MessageStatus.deliveryRank` internal (only MessageRepository.upgradeStatus uses it) |
| `ChatMessagePayload` (public init, all fields) | dispatcher decodes + reads every field; wire-format tests construct |
| `ChatMessageVariant` (.body, public Codable init/encode) | dispatcher switches on it; tests construct `.tyranny` |
| `ChatOutbox` (public init only) | OnymIOSApp + tests construct and inject; store/load/remove internal (interactor-only) |
| `ChatReceiptPayload` (+ explicit public init, `Kind`, all fields) | dispatcher decodes/reads; dispatcher tests construct |
| `ChatReceiptSending` / `NoopChatReceiptSender` (public init) / `ChatReceiptSender` (explicit public init(identity:inboxTransport:)) | AppDependencies/views hold the existential; dispatcher default + tests use Noop; app constructs the real sender. `ChatReceiptSender.inboxTag` internal |
| `ReadReceiptsPreference` (storageKey, isEnabled — setter internal, no external writer) | SettingsView (@AppStorage key), ChatThreadView, OnymIOSApp |
| `ChatVideoAttachment` (+ public init; fields public except `byteSize`) | dispatcher, bubble/thread views, ChatVideoAttachmentTests |
| `ChatVideoEncoder` (encode; `Encoded` + public init + fields) | UITestFakes + SendMessageInteractorTests construct canned encodings. `exportPreset` internal |
| `ChatVideoLoader` (init, fileURL(for:)) | OnymIOSApp, ChatThreadView |
| `ChatVoiceAttachment` (+ public init; fields public except `byteSize`) | dispatcher, ChatVoiceMessageView (waveform/duration), ChatVoiceAttachmentTests |
| `ChatVoiceEncoder` (encode, downsample, waveformBarCount; `Encoded` + public init + fields) | UITestFakes, ChatVoiceEncoderTests. `computeWaveform` internal |
| `ChatVoiceLoader` (init, fileURL(for:)) | OnymIOSApp, ChatVoiceMessageView/ChatBubbleCell |
| `ChatVoiceRecorder` (explicit `public override init()`, start, stop, cancel, duration, minimumDuration) | ChatInputPanelView. `isRecording`, `currentLevel`, `currentURL`, `RecordError` internal (panel tracks its own state, catches errors generically) |
| `MessageRepository` (init(store:), insert, needsDeliveredAck, markDeliveredAckSent, updateStatus, upgradeStatus, delete, removeForGroup, removeForOwner, removeAll, snapshots, currentMessages, search, latestMessage, unreadCount, changes) | dispatcher, app, chat/search views, MessageRepositoryTests — every method externally exercised |
| `MessageInsertOutcome` | dispatcher gates receipts on it; test fake returns it |
| `MessageStore` (protocol; requirements carry protocol access) | MessageRepositoryTests conform a fake; app injects SwiftDataMessageStore |
| `SendMessageInteractor` (public init, send, sendImage, sendVideo, sendAlbum, sendVoice, retry, delete; `SendError`; `maxUploadBytes`) | app + views + SendMessageInteractorTests. `categorize` internal (test mirrors it privately) |
| `SwiftDataMessageStore` (init() throws, inMemory(), all MessageStore witnesses public) | OnymIOSApp, dispatcher tests, SwiftDataMessageStoreTests |

Internal top-level type: `PersistedMessage` (@Model — zero references outside
this package; the encryption boundary keeps it private to the store).

## Decisions / ambiguities

- **`byteSize` internal on all three attachment descriptors** — never *read*
  outside the package (verified by grep); the explicit public inits still take
  it as a parameter, and cross-module Codable/Equatable synthesis is unaffected
  by an internal stored property. Flip to public if a UI progress bar ever needs it.
- **`ReadReceiptsPreference.isEnabled`** made `public internal(set)` — no
  external writer exists (Settings writes through `@AppStorage(storageKey)`).
- **Explicit public inits** added where memberwise/implicit inits were relied
  on externally: ChatImageAttachment, ChatVideoAttachment, ChatVoiceAttachment,
  ChatReceiptPayload, ChatReceiptSender, NoopChatReceiptSender,
  ChatVideoEncoder.Encoded, ChatVoiceEncoder.Encoded, ChatVoiceRecorder
  (`public override init()` for NSObject subclass). Param order matches the
  old memberwise order, so call sites compile unchanged.
- **Custom Codable bodies** (`ChatMediaAttachment`, `ChatMessageVariant`) got
  explicit `public init(from:)` / `public encode(to:)` — hand-written
  conformances don't get the synthesis access fix-up.
- `Packages/OnymInbox/…/IncomingMessageDispatcher.swift` does not yet
  `import OnymChatsCore`; that (and the app target's package wiring in
  project.yml) is the later integration step, per instructions.
- Files were syntax-checked with `swiftc -parse` only (no build, per the
  concurrent-extraction constraints).
