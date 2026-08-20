import CryptoKit
import Foundation
import OnymFoundation

/// `BackupPort` over the object-HTTP profile.
///
/// Wire notes, pinned against `UI-Backup-Object-HTTP.md`:
///
/// - Every `/v1/` request carries the four proof headers of §8. The
///   operator rebuilds the signed bytes from what it received, so a
///   mismatch surfaces as a refusal rather than as a weaker check.
/// - Bodies are JSON, camelCase, RFC 3339 UTC; chunk uploads are
///   `application/octet-stream`.
/// - Errors arrive as `{"error", "message", …per-code fields}` (§14) and
///   are mapped onto `BackupError` with the operator's own code kept
///   verbatim when we do not model it.
/// - **Redirects are never followed** and every response body is
///   bounded. An operator's `maximumRetainedSnapshots` is its own
///   figure with no signature behind it, so it bounds nothing on its
///   own (§13).
///
/// The manifest is *not* fetched or verified here. Manifest review is
/// the consent flow's job and already exists; duplicating it would put
/// two implementations of the same trust decision in the codebase.
public struct URLSessionBackupClient: BackupPort {
    let manifest: BackupOperatorManifest
    let material: BackupKeyMaterial
    let session: URLSession
    let entitlement: @Sendable () async -> Data?

    /// The read-write origin from the manifest the person consented to.
    /// Bound once and never rewritten — an operator does not get to move
    /// a signed request somewhere else.
    var endpoint: URL { manifest.endpoint }

    /// Caps on response bodies we are willing to read. Sealed streams
    /// are bounded by the operator's declared maximum instead — that
    /// figure is inside the signed manifest the person consented to.
    static let maxJSONResponseBytes = 4 << 20
    static let perSnapshotEntryBytes = 1 << 10
    /// Transfer framing only; unrelated to the sealing chunk size.
    static let uploadChunkBytes = 8 << 20
    /// The largest transfer chunk we will honour from a grant. A whole
    /// chunk is buffered to sign and send it, so this is a memory bound
    /// as much as an arithmetic one.
    static let maxUploadChunkBytes = 64 << 20
    /// Ceiling on the list-response cap, and on the snapshot count we
    /// will derive one from. Every other operator-controlled figure gets
    /// a refusal; this one was getting a trap, because a large enough
    /// declared limit overflows the multiplication that sizes the cap.
    static let maxListedSnapshots = 100_000
    static let maxListResponseBytes = 32 << 20

    /// How many bytes we are willing to read for a snapshot listing.
    ///
    /// Derived from the operator's declared limit, then clamped — the
    /// declaration is its own unsigned figure and bounds nothing on its
    /// own.
    var listResponseCap: Int {
        let declared = min(manifest.maximumRetainedSnapshots ?? 1_000, Self.maxListedSnapshots)
        let derived = max(declared, 0) * Self.perSnapshotEntryBytes
        return min(max(derived, 64 << 10), Self.maxListResponseBytes)
    }

    public init(
        manifest: BackupOperatorManifest,
        material: BackupKeyMaterial,
        session: URLSession = URLSessionBackupClient.defaultSession,
        entitlement: @escaping @Sendable () async -> Data? = { nil }
    ) {
        self.manifest = manifest
        self.material = material
        self.session = session
        self.entitlement = entitlement
    }

    /// Ephemeral, cookie-less, and redirect-refusing. Session state that
    /// outlives a request is linkable surface, and a redirect an
    /// operator controls would let it move a signed request to an origin
    /// the signature never covered.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(
            configuration: configuration,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
    }()

    // MARK: - BackupPort

    public func connect() async throws -> BackupConnection {
        let profileBytes = try await get(path: ["profile.json"], signed: false)
        let profile = try BackupImplementationProfile.review(raw: profileBytes)

        let digest = manifest.declaredTermsDigest
        guard let termsURL = manifest.termsURL(digest: digest) else {
            throw BackupError.termsUnavailable
        }
        let termsBytes = try await get(url: termsURL, signed: false)
        let signature = try? await get(url: termsURL.appendingPathExtension("sig"), signed: false)

        let terms = try BackupTerms.decode(raw: termsBytes, signature: signature.flatMap {
            Data(base64Encoded: $0) ?? $0
        })
        // The manifest is what the person consented to, so it is the
        // authority on which terms apply. A document served at the
        // declared address that hashes to something else is not a
        // version mismatch to tolerate.
        guard terms.termsId == digest else { throw BackupError.termsUnavailable }
        try verifyTermsSignature(terms)
        return BackupConnection(manifest: manifest, profile: profile, terms: terms)
    }

    public func preflight(_ snapshot: SealedSnapshot) async throws -> BackupPreflight {
        struct Body: Encodable {
            let version = 1
            let operationId: String
            let snapshotReference: SnapshotReference
            let acceptedTermsId: String
            let supersedes: String?
        }
        let body = try Self.encoder.encode(
            Body(
                operationId: snapshot.operationId,
                snapshotReference: snapshot.snapshotReference,
                acceptedTermsId: snapshot.acceptedTermsId,
                supersedes: snapshot.supersedes?.digest
            )
        )
        let data = try await post(path: ["v1", "preflight"], body: body)

        struct Response: Decodable {
            let uploadId: String?
            let chunkBytes: Int?
            let chunkCount: Int?
            let expiresAt: Date?
            let outcome: WireOutcome?
        }
        let response: Response = try decode(data)
        if let outcome = response.outcome, outcome.status == BackupOutcomeStatus.alreadyRetained.rawValue {
            return .alreadyRetained(try outcome.domain(operationId: snapshot.operationId,
                                                      componentId: manifest.componentId))
        }
        guard
            let uploadId = response.uploadId,
            let chunkBytes = response.chunkBytes, chunkBytes > 0,
            let chunkCount = response.chunkCount, chunkCount >= 0,
            let expiresAt = response.expiresAt
        else {
            throw BackupError.rejected(code: "malformed_preflight", message: nil)
        }
        return .granted(
            BackupUploadGrant(
                uploadId: uploadId,
                chunkBytes: chunkBytes,
                chunkCount: chunkCount,
                expiresAt: expiresAt
            )
        )
    }

    public func uploadSnapshot(
        _ snapshot: SealedSnapshot,
        grant: BackupUploadGrant
    ) async throws -> BackupOutcome {
        // The grant is operator-controlled arithmetic applied to our
        // file, so it is checked against the file before a byte moves.
        // An over-large `chunkBytes` would overflow the offset
        // computation and trap; a `chunkCount` one too small would
        // upload a truncated snapshot and only fail at commit, after
        // paying for the whole transfer.
        let size = snapshot.snapshotReference.sealedByteSize
        guard
            grant.chunkBytes > 0,
            grant.chunkBytes <= Self.maxUploadChunkBytes,
            grant.chunkCount >= 0,
            grant.chunkCount == (size + grant.chunkBytes - 1) / grant.chunkBytes
        else {
            throw BackupError.localFailure(reason: .invalidUploadGrant)
        }

        let handle = try FileHandle(forReadingFrom: snapshot.sealedBytesURL)
        defer { try? handle.close() }

        for index in 0..<grant.chunkCount {
            try handle.seek(toOffset: UInt64(index) * UInt64(grant.chunkBytes))
            guard let chunk = try handle.read(upToCount: grant.chunkBytes), !chunk.isEmpty else {
                throw BackupError.invalidReference
            }
            _ = try await send(
                method: "PUT",
                path: ["v1", "uploads", grant.uploadId, "chunks", String(index)],
                body: chunk,
                contentType: "application/octet-stream",
                signed: true,
                maxResponseBytes: Self.maxJSONResponseBytes
            )
        }

        let data = try await post(path: ["v1", "uploads", grant.uploadId, "commit"], body: Data())
        struct Response: Decodable { let outcome: WireOutcome }
        let response: Response = try decode(data)
        return try response.outcome.domain(
            operationId: snapshot.operationId,
            componentId: manifest.componentId
        )
    }

    public func listSnapshots() async throws -> [RetainedSnapshot] {
        let data = try await get(
            path: ["v1", "snapshots"],
            signed: true,
            maxResponseBytes: listResponseCap
        )
        struct Row: Decodable {
            let snapshotReference: SnapshotReference
            let acceptedTermsId: String
            let retainedAt: Date
            let retainedUntil: Date?
            let supersedes: String?
            let status: String?
        }
        let rows: [Row] = try decode(data)
        return rows.map {
            RetainedSnapshot(
                snapshotReference: $0.snapshotReference,
                acceptedTermsId: $0.acceptedTermsId,
                retainedAt: $0.retainedAt,
                retainedUntil: $0.retainedUntil,
                supersedes: $0.supersedes,
                status: $0.status.flatMap(BackupOutcomeStatus.init(rawValue:)) ?? .retained
            )
        }
    }

    public func downloadSnapshot(_ reference: SnapshotReference, to destination: URL) async throws {
        try await stream(
            path: ["v1", "snapshots", reference.digestHex],
            to: destination,
            maxBytes: reference.sealedByteSize
        )
    }

    public func eraseSnapshot(scope: ErasureScope) async throws -> ErasureReceipt {
        struct Body: Encodable {
            let version = 1
            let scope: String
        }
        let body = try Self.encoder.encode(Body(scope: scope.wireValue))
        let data = try await post(path: ["v1", "erasures"], body: body)
        return try ErasureReceipt.decode(raw: data)
    }

    public func exportSnapshots(to directory: URL) async throws -> BackupExport {
        let manifestBytes = try await get(
            path: ["v1", "exports"],
            signed: true,
            maxResponseBytes: listResponseCap
        )
        struct Entry: Decodable {
            let snapshotReference: SnapshotReference
            let acceptedTermsId: String
            let retainedAt: Date
        }
        struct Envelope: Decodable { let snapshots: [Entry] }
        let envelope: Envelope = try decode(manifestBytes)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var exported: [BackupExport.ExportedSnapshot] = []
        for entry in envelope.snapshots {
            let url = directory.appending(path: "\(entry.snapshotReference.digestHex).seal")
            try await stream(
                path: ["v1", "exports", entry.snapshotReference.digestHex],
                to: url,
                maxBytes: entry.snapshotReference.sealedByteSize
            )
            // Exported bytes are the same bytes under the same
            // reference — that is what lets a migration re-upload them
            // without re-sealing — so a mismatch here means the export
            // is not portable and must not be presented as one.
            try BackupOpener.verify(sealedURL: url, matches: entry.snapshotReference)
            exported.append(
                BackupExport.ExportedSnapshot(
                    snapshotReference: entry.snapshotReference,
                    acceptedTermsId: entry.acceptedTermsId,
                    retainedAt: entry.retainedAt,
                    sealedBytesURL: url
                )
            )
        }
        return BackupExport(directory: directory, snapshots: exported, receipts: [])
    }

    public func queryOutcome(operationId: String) async throws -> BackupOutcome? {
        do {
            let data = try await get(path: ["v1", "operations", operationId], signed: true)
            struct Response: Decodable { let outcome: WireOutcome }
            let response: Response = try decode(data)
            return try response.outcome.domain(
                operationId: operationId,
                componentId: manifest.componentId
            )
        } catch BackupError.rejected(let code, _) where code == "http_404" || code == "not_found" {
            // No record. This stays `unknown` for the caller —
            // reconciliation moves to the reference, and silence is
            // never promoted to success.
            return nil
        }
    }
}
