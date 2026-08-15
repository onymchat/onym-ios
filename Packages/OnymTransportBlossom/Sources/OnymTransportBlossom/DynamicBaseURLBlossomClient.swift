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
}
