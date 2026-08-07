# OnymPersistence — extraction notes

## Files moved (plain `mv`, from `Sources/OnymIOS/Persistence/`)

- `InvitationStore.swift` → `Sources/OnymPersistence/InvitationStore.swift`
- `SwiftDataInvitationStore.swift` → `Sources/OnymPersistence/SwiftDataInvitationStore.swift`

The now-empty `Sources/OnymIOS/Persistence/` directory was removed.

## Dependencies

- `OnymIdentity` — needed for `IdentityID` (field of `IncomingInvitationRecord`, decode path). Both files already carried `import OnymIdentity`.
- `OnymFoundation` — needed for `StorageEncryption` (at-rest AES-GCM wrap in `SwiftDataInvitationStore`). File already carried `import OnymFoundation`.
- No trims: both listed dependencies are genuinely used.

## Public surface (each symbol justified by an external consumer)

| Symbol | Why public |
|---|---|
| `protocol InvitationStore` | Consumed as `any InvitationStore` in `Sources/OnymIOS/OnymIOSApp.swift` and `Sources/OnymIOS/Inbox/IncomingInvitationsRepository.swift`; conformed to by test fakes (`Tests/OnymIOSTests/Support/InMemoryInvitationStore.swift`, `InboxFanoutInteractorTests.swift`, `IncomingMessageDispatcherTests.swift`). Requirements are called through the public existential. |
| `enum IncomingInvitationStatus` | Passed to `updateStatus` by `IncomingInvitationsRepository`; used in tests (`InvitationDecryptorTests`, `SwiftDataInvitationStoreTests`, fakes). Cases inherit public. |
| `struct IncomingInvitationRecord` | Typealiased (`IncomingInvitation`) and consumed in `IncomingInvitationsRepository`; constructed in tests and test fakes → explicit `public init` (memberwise would be internal) and all stored properties `public` (read by repository/tests). |
| `actor SwiftDataInvitationStore` | Constructed in `OnymIOSApp.swift` (`try? SwiftDataInvitationStore()` with `.inMemory()` fallback); `.inMemory()` + direct method calls in `SwiftDataInvitationStoreTests` and `IncomingMessageDispatcherChatMessageTests`. Public members: `init() throws`, `static func inMemory()`, and the five protocol witnesses (`list`, `save`, `updateStatus`, `delete`, `deleteOwner`) — witnesses of a public protocol on a public type must be public, and the tests also call them on the concrete type. `private init(container:)` stays private. |

## Kept internal

- `@Model final class PersistedInvitation` — referenced outside this package only in doc comments (`Sources/OnymIOS/Group/PersistedGroup.swift`), never in code. Per instructions, the `@Model` class stays internal; only the store protocol/concrete store are consumed outside.

## Decisions / ambiguities

- `StorageEncryption.swift` was already extracted to `OnymFoundation` by a sibling agent (confirmed at `Packages/OnymFoundation/Sources/OnymFoundation/StorageEncryption.swift`); this package only imports it.
- On-disk store path still uses the `OnymIOS` Application Support subdirectory name (`Application Support/OnymIOS/Invitations.store`) — kept as-is to avoid a silent data-location migration.
- `project.yml` / xcodeproj not touched (integration step will wire the app target to this package).
