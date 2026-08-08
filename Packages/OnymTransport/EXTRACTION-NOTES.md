# OnymTransport extraction notes

## Files moved (plain `mv`, no git)

- `Sources/OnymIOS/Transport/Transport.swift` -> `Packages/OnymTransport/Sources/OnymTransport/Transport.swift`
- `Sources/OnymIOS/Transport/Nostr/NostrSigner.swift` -> `Packages/OnymTransport/Sources/OnymTransport/NostrSigner.swift` (flattened; the `Nostr/` subfolder was not carried over — the file is protocols/enum only, no Nostr implementation code)

## Dependencies

`Package.swift` declares **no dependencies** (Foundation only), as required. Nothing to trim — the task listed none and the files need none.

## Public surface (12 top-level symbols, all externally referenced)

Consumers cited below are current locations under `Sources/OnymIOS` / `Tests/OnymIOSTests`; concurrent extractions may relocate them, but the reference survives either way.

| Symbol | Public members | Justifying consumers (examples) |
|---|---|---|
| `TransportEndpoint` | `url`, `init(url:)` | constructed in `OnymIOSApp.swift:578`; `endpoint.url` read in `NostrMessageTransport.swift:98`, `NostrInboxTransport.swift:110`ff; fakes conform in tests (`FakeInboxTransport.swift:34`) |
| `TransportTopic` | `rawValue`, `init(rawValue:)` | constructed in `NostrMessageTransportTests.swift`; `topic.rawValue` read in `NostrMessageTransport.swift:51,151,160`. Public `RawRepresentable` conformance also forces both witnesses public |
| `TransportInboxID` | `rawValue`, `init(rawValue:)` | constructed in `InboxFanoutInteractor.swift:84`, `CreateGroupInteractor.swift:701`, `JoinRequestApprover.swift:318`, many tests; `inbox.rawValue` read in `NostrInboxTransport.swift:48-50`, `UITestFakes.swift:136` |
| `InboundMessage` | `init(topic:payload:receivedAt:messageID:)` only — **stored properties stay internal** | constructed (yielded) in `NostrMessageTransport.swift:168`; no external code currently reads its fields (no consumer iterates `MessageTransport.subscribe` today), so per the minimal-surface rule the fields are internal. See open questions |
| `InboundInbox` | `inbox`, `payload`, `receivedAt`, `messageID`, `init(...)` | constructed in `NostrInboxTransport.swift:207`, `UITestFakes.swift:139`, many test fakes; all four fields read externally (`IncomingInvitationsInteractor.swift:31-34`, `InboxFanoutInteractor.swift:137-140`, `IntroInboxPump.swift:105-108`, `FakeInboxTransport.swift:73` reads `.inbox`) |
| `PublishReceipt` | `acceptedBy`, `init(messageID:acceptedBy:)` — **`messageID` stays internal** | constructed in `NostrInboxTransport.swift:37`, `UITestFakes.swift:150`, test fakes; `receipt.acceptedBy` read in `CreateGroupInteractor.swift:709`, `JoinRequestApprover.swift:327`, `JoinRequestSender.swift:96`, `GroupStateVerifier.swift:176`, `SendMessageInteractor.swift:921`. No external read of `receipt.messageID` found (the `.messageID` hits elsewhere are `InboundInbox`/`ChatMessagePayload`) |
| `TransportError` | all cases (enum cases share the enum's access) | thrown in `NostrInboxTransport.swift:145,171,177`, `NostrMessageTransport.swift:120,138`; matched exhaustively in `SendMessageInteractor.swift:949-957` (including `.invalidPayload` and `.unreachable(let code)`); tests store it (`SendMessageInteractorTests.swift:807`) |
| `MessageTransport` | all requirements (implicit) | conformed to by `NostrMessageTransport.swift:9` |
| `InboxTransport` | all requirements (implicit) | existential `any InboxTransport` held across the app (`OnymIOSApp.swift:14`, `SendMessageInteractor.swift:16`, `InboxFanoutInteractor.swift:17`, ...); conformed to by `NostrInboxTransport.swift:11` and ~8 test fakes; all five requirements called externally |
| `NostrSigner` | both requirements | conformed to by `OnymNostrSigner.swift:9`; `publicKey()`/`signEventID` called in `NostrEvent.swift:67` path and `BlossomClient.swift:80` path |
| `NostrEphemeralSignerProvider` | requirement | conformed to by `OnymNostrSignerProvider` (`OnymNostrSigner.swift:47`); `makeEphemeralSigner()` called in `NostrMessageTransport` / `NostrInboxTransport` / `BlossomClient` |
| `NostrSignerError` | all cases | thrown in `OnymNostrSigner.swift:14,25,38`; pattern-matched with associated values in `OnymNostrSignerTests.swift:20,58` |

Explicit public inits were added to all four public structs constructed outside the package (memberwise inits are internal). No file was blanket-published; every keyword was placed per-declaration.

## Ambiguities decided

1. **`InboundMessage` fields internal**: strictly minimal per the access-control rule. The doc comment says callers may dedupe by `messageID`, and any future `MessageTransport.subscribe` consumer will need the fields public — widen at integration if a consumer appears. Same for `PublishReceipt.messageID`.
2. **`TransportTopic`/`TransportInboxID` non-failable `init(rawValue:)`** kept as-is; a non-failable init validly witnesses `RawRepresentable.init?(rawValue:)`.
3. `.url` hits in `Settings/*View.swift` and `OnymIOSApp.swift:184` are on other endpoint types (relayer/Blossom config models), not `TransportEndpoint`; they did not drive the decision — `NostrMessageTransport`/`NostrInboxTransport` reads did.
