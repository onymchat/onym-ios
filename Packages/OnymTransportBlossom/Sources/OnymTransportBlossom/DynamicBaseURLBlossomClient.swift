import Foundation

/// `BlossomClient` that resolves its base URL per operation instead of
/// freezing it at construction. Wraps a base-URL provider (typically
/// "the first endpoint in `BlossomServersRepository` right now") and a
/// client factory (typically `URLSessionBlossomClient.init`), so a
/// server change in Settings — or a pick made during onboarding —
/// takes effect on the very next upload/download, no relaunch needed.
///
/// `URLSessionBlossomClient` is a cheap value type over a shared
/// `URLSession`, so building one per operation costs nothing; the
/// factory seam exists so tests can capture the resolved URL with a
/// fake inner client.
public struct DynamicBaseURLBlossomClient: BlossomClient {
    /// Resolves the base URL to use for the next operation.
    private let resolveBaseURL: @Sendable () async -> URL
    /// Builds the underlying client for a resolved base URL.
    private let makeClient: @Sendable (URL) -> any BlossomClient

    public init(
        resolveBaseURL: @escaping @Sendable () async -> URL,
        makeClient: @escaping @Sendable (URL) -> any BlossomClient
    ) {
        self.resolveBaseURL = resolveBaseURL
        self.makeClient = makeClient
    }

    public func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
        try await makeClient(await resolveBaseURL()).upload(blob, mimeType: mimeType)
    }

    public func download(sha256: String) async throws -> Data {
        try await makeClient(await resolveBaseURL()).download(sha256: sha256)
    }

    /// Pin to `serverURL`: returns the inner client built for exactly
    /// that URL, so a multi-blob send that stamped the URL into its
    /// metadata uploads every blob there even if the configuration
    /// changes mid-send.
    ///
    /// This is the TRUSTED binding level: callers vouch for the URL —
    /// it comes from the user's own configuration (the per-send upload
    /// pin, retry's re-upload to the self-stamped server), never from
    /// peer-influenced bytes. The scheme is deliberately NOT
    /// second-guessed here, so a hand-typed http://192.168.x local-dev
    /// endpoint binds exactly as the user configured it.
    /// Peer-influenced stamps must never reach this directly — they go
    /// through `BlossomServerStampPolicy` (OnymChatsCore), which
    /// enforces https + the user's configured allowlist and then binds
    /// to the allowlist's own URL.
    ///
    /// Falls back to `self` (live resolution) when the string isn't a
    /// usable absolute URL — `URL(string:)` happily parses a schemeless
    /// "blossom.example" as a relative URL that every request would
    /// then fail against, so scheme and host are required.
    public func bound(toServer serverURL: String) -> any BlossomClient {
        guard let url = URL(string: serverURL),
              url.scheme != nil,
              let host = url.host(), !host.isEmpty
        else { return self }
        return makeClient(url)
    }
}
