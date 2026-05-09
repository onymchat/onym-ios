import Foundation

/// One Nostr-relay entry the inbox transport connects to. Pure value
/// type — no behaviour, just the wire shape persisted in UserDefaults.
///
/// Distinct from the chain-side `RelayerEndpoint` because the two
/// transports talk to completely different services:
///   - `RelayerEndpoint` → HTTPS Soroban contract proxy
///     (`POST https://relayer.onym.chat/`).
///   - `NostrRelayEndpoint` → Nostr WebSocket relay (strfry behind
///     nginx at `wss://nostr.onym.chat`).
///
/// Sharing the type would couple two unrelated concerns and force
/// the manifest schema to track both — cleaner to keep them apart.
struct NostrRelayEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Display label. Defaults to the URL's host for user-added
    /// entries; the app-shipped seed carries a friendlier name.
    let name: String
    /// `wss://` (or `ws://` for local dev) URL of the relay.
    let url: URL
    /// `true` for the app-shipped default seed, `false` for entries
    /// the user added in Settings. UI uses this to render a small
    /// "Default" badge so the user can distinguish their own
    /// additions from what shipped with the app.
    let isDefault: Bool

    /// Stable id for SwiftUI list diffing — URL is the natural key.
    var id: URL { url }

    /// Convenience for synthesising an entry from a custom URL the
    /// user typed. Name defaults to the URL's host so the row is
    /// recognisable even before the user gives it a friendlier label.
    static func custom(url: URL) -> NostrRelayEndpoint {
        NostrRelayEndpoint(
            name: url.host() ?? url.absoluteString,
            url: url,
            isDefault: false
        )
    }
}
