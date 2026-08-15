import Foundation

/// Persisted Blossom-server configuration. Single field — the list of
/// servers media blobs are uploaded to / downloaded from — plus a
/// sticky "user has interacted" flag so the next app boot doesn't
/// re-seed the default if the user explicitly cleared the list.
///
/// V1 uploads to the **first** configured server (the client resolves
/// one base URL per operation); the rest of the list is there so a user
/// can swap Onym's default for their own self-hosted Blossom server.
/// Changes apply to the next upload/download. Mirrors
/// `NostrRelaysConfiguration`.
public struct BlossomServersConfiguration: Codable, Equatable, Sendable {
    public var endpoints: [BlossomServerEndpoint]
    /// Flips to `true` after the first user mutation (add / remove).
    /// Sticky — once set, the seed-on-empty logic in
    /// `BlossomServersRepository.init` never re-fires, so a user who
    /// clears the list keeps an empty list across launches.
    public var hasUserInteracted: Bool

    public init(endpoints: [BlossomServerEndpoint], hasUserInteracted: Bool) {
        self.endpoints = endpoints
        self.hasUserInteracted = hasUserInteracted
    }

    public static let empty = BlossomServersConfiguration(
        endpoints: [],
        hasUserInteracted: false
    )

    /// App-shipped default — single Onym-operated Blossom server. Used
    /// at first launch (or any launch where the persisted config is
    /// empty AND `hasUserInteracted` is false).
    static let seed = BlossomServersConfiguration(
        endpoints: [
            BlossomServerEndpoint(
                name: "Onym Official",
                url: URL(string: "https://blossom.onym.app")!,
                isDefault: true
            )
        ],
        hasUserInteracted: false
    )
}
