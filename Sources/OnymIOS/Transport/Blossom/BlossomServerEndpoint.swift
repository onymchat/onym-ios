import Foundation

/// One Blossom-server entry media blobs are uploaded to / downloaded
/// from. Pure value type — no behaviour, just the wire shape persisted
/// in UserDefaults. Mirrors `NostrRelayEndpoint`.
///
/// Blossom (BUD-01) servers speak plain HTTPS (`PUT /upload`,
/// `GET /<sha256>`), so the URL scheme here is `https://` (or `http://`
/// for local dev) — unlike the `wss://` Nostr relays.
struct BlossomServerEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Display label. Defaults to the URL's host for user-added
    /// entries; the app-shipped seed carries a friendlier name.
    let name: String
    /// `https://` (or `http://` for local dev) base URL of the server.
    let url: URL
    /// `true` for the app-shipped default seed, `false` for entries
    /// the user added in Settings. UI uses this to render a small
    /// "Default" badge.
    let isDefault: Bool

    /// Stable id for SwiftUI list diffing — URL is the natural key.
    var id: URL { url }

    /// Convenience for synthesising an entry from a custom URL the
    /// user typed. Name defaults to the URL's host so the row is
    /// recognisable even before the user gives it a friendlier label.
    static func custom(url: URL) -> BlossomServerEndpoint {
        BlossomServerEndpoint(
            name: url.host() ?? url.absoluteString,
            url: url,
            isDefault: false
        )
    }
}
