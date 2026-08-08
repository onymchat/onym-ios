# OnymTransportBlossom — extraction notes

## Files moved (from `Sources/OnymIOS/Transport/Blossom/`)

- `BlossomClient.swift`
- `BlossomServerEndpoint.swift`
- `BlossomServersConfiguration.swift`
- `BlossomServersRepository.swift`
- `BlossomServersSelectionStore.swift`
- `KnownBlossomServersFetcher.swift`

## Dependencies

- `OnymTransport` — `NostrSigner` / `NostrEphemeralSignerProvider` protocols used by `URLSessionBlossomClient`.
- `OnymTransportNostr` — `NostrEvent.build(kind: 24242, …)` for the BUD-01 auth header (referenced by name; that package is being extracted in parallel).
- `OnymFoundation` — `SignedAsset.verify` in `GitHubReleasesKnownBlossomServersFetcher` (H-3 detached-signature check).

No trims — all three listed/allowed dependencies are genuinely used.

## Code change beyond imports/access

- `URLSessionBlossomClient.upload` used `ChatImageCrypto.sha256Hex(_:)`, which lives in the app module (`Sources/OnymIOS/Chats/ChatImageCrypto.swift`) and is out of scope for a transport package. Replaced with a private local `sha256Hex` helper (identical implementation, CryptoKit `SHA256`). No behavior change.

## Public surface (justifying consumer for each)

### BlossomClient.swift
- `public struct BlobDescriptor` + `public init(sha256:url:size:)` — constructed by `Sources/OnymIOS/UITestFakes.swift` (`UITestBlossomClient`) and `Tests/OnymIOSTests/SendMessageInteractorTests.swift` (`FakeBlossomClient`). **Stored properties left internal**: no external code reads `.sha256`/`.url`/`.size` on a `BlobDescriptor` (the `.sha256` hits in tests are on attachment types); external fakes only construct it.
- `public protocol BlossomClient` — `any BlossomClient` in `OnymIOSApp`, `ChatImageLoader`, `ChatVideoLoader`, `ChatVoiceLoader`, `SendMessageInteractor`; conformed to by `UITestBlossomClient` and `FakeBlossomClient`.
- `public enum BlossomError` — `.badStatus` / `.malformedResponse` thrown by `UITestFakes.swift`, `ChatImageLoader.swift`, `SendMessageInteractorTests.swift`. (`.invalidURL` rides along; enum cases can't be scoped.)
- `public struct URLSessionBlossomClient`
  - `public init(baseURL:signerProvider:session:authTTLSeconds:)` (explicit; memberwise was internal) — `OnymIOSApp.swift`, `SendMessageInteractor.swift` call `init(baseURL:signerProvider:)`.
  - `public static defaultBaseURL` — `OnymIOSApp.swift:186`, `SendMessageInteractor.swift:78/81`.
  - `public func upload/download` — protocol witnesses of the public protocol (must be public).
  - `public static authorizationHeader(action:sha256:ttlSeconds:signer:)` — `Tests/OnymIOSTests/ChatImagePipelineTests.swift:72` (was "internal for tests"; cross-module now requires public — doc comment updated).
  - Stored properties stay internal.

### BlossomServerEndpoint.swift
- `public struct BlossomServerEndpoint`; `public let name/url/isDefault` (read by `BlossomRelaySettingsView` and repository tests), `public var id` (SwiftUI `Identifiable` in the settings list), `public init(name:url:isDefault:)` (explicit; tests construct memberwise-style), `public static custom(url:)` (`BlossomRelaySettingsFlow.swift:65`, tests).

### BlossomServersConfiguration.swift
- `public struct BlossomServersConfiguration`; `public var endpoints` (`BlossomRelaySettingsView`, `OnymIOSApp:185`), `public var hasUserInteracted` (`BlossomServersRepositoryTests` assert `store.load().hasUserInteracted`), `public init(endpoints:hasUserInteracted:)` (tests), `public static empty` (`BlossomRelaySettingsFlow` initial state, tests).
- `static seed` stays **internal** — no external references.

### BlossomServersRepository.swift
- `public actor BlossomServersRepository`; public members: `init(store:fetcher:)` (`OnymIOSApp`, tests), `currentEndpoints()` (tests, flow tests), `start()` (`OnymIOSApp:529`), `refresh()` (tests), `addEndpoint(_:)` (flow, tests), `removeEndpoint(url:)` (flow, tests), `resetToDefault()` (flow, tests), `snapshots` (flow, tests).
- **Internal** (no external references): `currentConfiguration()`, `clearAll()`.

### BlossomServersSelectionStore.swift
- `public protocol BlossomServersSelectionStore` — parameter type of the public repository init; `load()` called externally on concrete stores.
- `public struct UserDefaultsBlossomServersSelectionStore` + `public init(defaults:)` + `public load/save` — `OnymIOSApp:170` constructs it and calls `.load()` directly (line 185); witnesses of a public protocol must be public.
- `public final class InMemoryBlossomServersSelectionStore` + `public init(initial:)` + `public load/save` — constructed throughout `BlossomServersRepositoryTests` / `BlossomRelaySettingsFlowTests`; tests call `store.load()`.

### KnownBlossomServersFetcher.swift
- `public protocol KnownBlossomServersFetcher` — `OnymIOSApp:173` (`any KnownBlossomServersFetcher`), `StubFetcher` conformance in tests.
- `public struct GitHubReleasesKnownBlossomServersFetcher` + `public init(url:session:decoder:)` + `public fetchLatest()` — constructed in `OnymIOSApp:176/178`.
- `public static defaultURL` — no direct external reference, but it is the default argument of the public init and Swift rejects internal symbols in default argument values of public functions (verified with a scratch compile). Documented on the declaration.
- **Internal**: `KnownBlossomServersDocument`, `KnownBlossomServersFetchError` (no external references; the error escapes `fetchLatest` as an opaque `Error`, which is fine since no external code matches on it).

## Ambiguities / decisions

- `BlobDescriptor` is externally opaque (public init, internal fields). If a future consumer needs to read descriptor fields, its properties will need `public let`.
- Tests in `Tests/OnymIOSTests` were treated as external consumers per instructions; if those Blossom tests later move into this package's own test target, `authorizationHeader`, `refresh()`, `InMemoryBlossomServersSelectionStore`, `hasUserInteracted`, and `BlossomServersConfiguration.init` could be tightened back to internal.
- `NostrEvent.build(kind:tags:content:signer:)` is referenced by name trusting the parallel `OnymTransportNostr` extraction (not read); it must end up public there with that signature, and `NostrEvent` must be `Encodable` publicly.
