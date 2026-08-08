# OnymTransportNostr — extraction notes

Extracted from `Sources/OnymIOS/Transport/Nostr/` (plain `mv`, no git commands).

## Files moved (9)

- `KnownNostrRelaysFetcher.swift`
- `NostrEvent.swift`
- `NostrInboxTransport.swift`
- `NostrMessageTransport.swift`
- `NostrRelayConnection.swift`
- `NostrRelayEndpoint.swift`
- `NostrRelaysConfiguration.swift`
- `NostrRelaysRepository.swift`
- `NostrRelaysSelectionStore.swift`

`NostrSigner.swift` was already moved to OnymTransport and is not part of this package.

## Dependencies (no trims)

- `OnymTransport` — `NostrSigner` / `NostrEphemeralSignerProvider` protocols,
  `InboxTransport` / `MessageTransport` protocols and their value types
  (`TransportEndpoint`, `TransportInboxID`, `TransportTopic`, `PublishReceipt`,
  `InboundInbox`, `InboundMessage`, `TransportError`).
- `OnymFoundation` — `SignedAsset.verify` (H-3 detached-signature check in
  `GitHubReleasesKnownNostrRelaysFetcher.fetchLatest`).

Both listed dependencies are genuinely used; nothing trimmed. No import edits
were needed — the moved files already carried `import OnymTransport` /
`import OnymFoundation` from the earlier extraction of those packages.

## Public surface and its justification

Consumers found by grep across `Sources/`, `Tests/`, and other `Packages/`:

| Symbol | Public members | Consumer |
|---|---|---|
| `KnownNostrRelaysFetcher` (protocol) | `fetchLatest()` (implicit) | `OnymIOSApp.swift` (`any KnownNostrRelaysFetcher` binding); `NostrRelaysRepositoryTests.StubFetcher` conforms |
| `GitHubReleasesKnownNostrRelaysFetcher` | `init()`, `fetchLatest()` (protocol witness) | `OnymIOSApp.swift` constructs with no args. The parameterized `init(url:session:decoder:)` and `defaultURL` stay internal — no external caller; a new zero-arg `public init()` delegates to it (a public init can't have a default argument referencing the internal `defaultURL`). |
| `NostrEvent` | stored `id/pubkey/createdAt/kind/tags/content/sig`, explicit memberwise `init`, `build`, `verifyEventID()`, `displayMilliseconds` | `OnymTransportBlossom/BlossomClient.swift` (`NostrEvent.build`, `JSONEncoder().encode`); `NostrEventTests`, `ChatImagePipelineTests`, `NostrInboxTransportTests`, `NostrMessageTransportTests` (direct construction + all listed members). `jsonObject` stays internal (only relay framing uses it). |
| `NostrInboxTransport` | `init(signerProvider:)`, `connect/disconnect/send/subscribe/unsubscribe` (witnesses of public `InboxTransport`), `buildSendEvent`, `subscriptionFilters` | `OnymIOSApp.swift` constructs; `NostrInboxTransportTests` uses the two statics. Witnesses must be public because a public type conforms to a public protocol. |
| `NostrMessageTransport` | `connect/disconnect/publish/subscribe/unsubscribe` (witnesses of public `MessageTransport`), `buildPublishEvent` | `NostrMessageTransportTests` uses `buildPublishEvent`. **`init` stays internal** — nothing outside the package constructs it today. |
| `NostrRelayEndpoint` | `name`, `url`, `isDefault`, `id` (Identifiable witness), `custom(url:)`, explicit memberwise `init` | `NostrRelaySettingsFlow.swift` (`custom`), `NostrRelaySettingsView.swift` (`name`/`isDefault` via list rows), `NostrRelaysRepositoryTests` (memberwise init, `url`, `isDefault`) |
| `NostrRelaysConfiguration` | `endpoints`, `hasUserInteracted`, explicit memberwise `init`, `static empty` | `NostrRelaySettingsFlow.swift` (`State.snapshot`, `.empty`), settings views (`endpoints`), `NostrRelaysRepositoryTests` (init, both fields), `InMemoryNostrRelaysSelectionStore.init` default arg (`.empty`). **`static seed` stays internal** — only referenced externally in comments. |
| `NostrRelaysRepository` | `init(store:fetcher:)`, `currentEndpoints`, `start`, `refresh`, `addEndpoint`, `removeEndpoint`, `resetToDefault`, `snapshots` | `OnymIOSApp.swift` (init, `start`, `currentEndpoints`), `NostrRelaySettingsFlow.swift` (`snapshots`, `addEndpoint`, `removeEndpoint`, `resetToDefault`), `NostrRelaysRepositoryTests` (adds `refresh`). **`currentConfiguration()` and `clearAll()` stay internal** — no external references. |
| `NostrRelaysSelectionStore` (protocol) | `load()`, `save(_:)` (implicit) | Part of `NostrRelaysRepository.init`'s public signature; tests call `store.load()` on concrete stores |
| `UserDefaultsNostrRelaysSelectionStore` | `init(defaults:)`, `load`, `save` (witnesses) | `OnymIOSApp.swift` constructs with no args |
| `InMemoryNostrRelaysSelectionStore` | `init(initial:)`, `load`, `save` (witnesses) | `NostrRelaysRepositoryTests`, `NostrRelaySettingsFlowTests` (construct + `load()`) |

Internal (no external references, kept module-private):

- `NostrRelayConnection` (actor) — only mentioned in an external test *comment*;
  both transports use it internally.
- `KnownNostrRelaysDocument`, `KnownNostrRelaysFetchError`
- `NostrEvent.jsonObject`, `NostrEvent.CodingKeys`
- `NostrRelaysConfiguration.seed`
- `NostrRelaysRepository.currentConfiguration()`, `.clearAll()`
- `GitHubReleasesKnownNostrRelaysFetcher.defaultURL`, `.init(url:session:decoder:)`,
  stored `url/session/decoder`
- Both transports' `fileprivate actor State`

## Decisions / ambiguities

- Several members are public **solely because the app-target test suite
  (`Tests/OnymIOSTests`) references them** (`buildSendEvent`,
  `subscriptionFilters`, `buildPublishEvent`, `refresh`,
  `InMemoryNostrRelaysSelectionStore`, `NostrEvent` memberwise init,
  `verifyEventID`, `displayMilliseconds`). If those tests later move into this
  package (per the repo's tests-in-final-PR convention), they can drop back to
  internal with `@testable import`. Doc comments that said "internal for tests"
  were reworded to match.
- `OnymTransportBlossom/BlossomClient.swift` calls `NostrEvent.build` but its
  package had no `Package.swift` at extraction time (sibling agent in flight).
  The integration step must add `OnymTransportNostr` as a dependency of
  `OnymTransportBlossom` (and `import OnymTransportNostr` in
  `BlossomClient.swift`), or move `NostrEvent` down into `OnymTransport` if a
  Blossom→Nostr package edge is unwanted.
- `NostrMessageTransport` is currently constructed nowhere outside the package
  (only its static `buildPublishEvent` is used, by tests), so its `init` stays
  internal; flip to public when a consumer appears.
- Codable/Equatable/Hashable synthesis is unaffected by the explicit public
  memberwise inits; cross-module `JSONDecoder().decode(NostrEvent.self, ...)`
  in tests works through the public `Decodable` conformance.
- The now-empty `Sources/OnymIOS/Transport/Nostr/` directory was removed.
