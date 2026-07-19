import Foundation

/// Persisted Nostr-relay configuration. Single field — the list of
/// relays the inbox transport should connect to — plus a sticky
/// "user has interacted" flag so the next app boot doesn't re-seed
/// the default if the user explicitly cleared the list.
///
/// V1 connects to **every** configured endpoint at the same time;
/// there's no primary/strategy concept like the chain relayer has.
/// Nostr fanout is by design: clients publish to and listen on all
/// configured relays so a single relay outage doesn't drop traffic.
struct NostrRelaysConfiguration: Codable, Equatable, Sendable {
    var endpoints: [NostrRelayEndpoint]
    /// Flips to `true` after the first user mutation (add / remove).
    /// Sticky — once set, the seed-on-empty logic in
    /// `NostrRelaysRepository.init` never re-fires, so a user who
    /// clears the list keeps an empty list across launches.
    var hasUserInteracted: Bool

    static let empty = NostrRelaysConfiguration(
        endpoints: [],
        hasUserInteracted: false
    )

    /// App-shipped default — single Onym-operated relay. Used at
    /// first launch (or any launch where the persisted config is
    /// empty AND `hasUserInteracted` is false).
    static let seed = NostrRelaysConfiguration(
        endpoints: [
            NostrRelayEndpoint(
                name: "Onym Official",
                url: URL(string: "wss://nostr.onym.chat")!,
                isDefault: true
            )
        ],
        hasUserInteracted: false
    )
}
