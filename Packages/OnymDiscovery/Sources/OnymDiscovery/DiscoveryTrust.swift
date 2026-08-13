import Foundation
import CryptoKit
import OnymFoundation

/// Typed mirror of the profile's error table
/// (`Discovery-Static-Ed25519.md` §9 / `Discovery.md` §12). `reason`
/// strings are diagnostic, not part of the contract.
public enum DiscoveryTrustError: Error, Equatable, Sendable {
    /// Signature/key-pin failure, unknown top-level field, bad
    /// version/profile/seat, expired `validUntil`, oversize, or URI
    /// violation in a provider manifest.
    case providerManifestInvalid(reason: String)
    /// Signature failure, sequence gap/repeat/rollback,
    /// `previousDigest` mismatch, duplicate `componentId`, unknown
    /// top-level field, or oversize in a snapshot.
    case snapshotInvalid(reason: String)
    /// `expiresAt` in the past.
    case snapshotExpired
    /// `policyUri` unreachable or bytes ≠ `policyDigest`.
    case policyUnavailable
    /// Destination manifest fetch failure / timeout / oversize.
    case entryManifestUnavailable
    /// Fetched destination bytes ≠ the entry's `manifest.digest`.
    case entryManifestMismatch
    /// Destination seat signature/schema/expiry failure.
    case entryManifestInvalid(reason: String)
    /// Always, for server-side filters — this profile has none.
    case queryUnsupported
    /// HTTP 429 from the static host.
    case rateLimited
    /// Two configured sources bind the same `componentId` to different
    /// manifest digests.
    case sourceConflict
}

/// Client verification for the static-snapshot / Ed25519 discovery
/// profile (§6). **Hard-enforced** — unlike `ContractsTrust`'s soft
/// mode for the legacy lists, there is no accept-anyway path here: a
/// document that fails any check is rejected. Ed25519 verification
/// reuses OnymFoundation's `Ed25519DetachedSignatureVerifier`, keyed
/// on the per-source pinned operator key instead of the bundled key.
public enum DiscoveryTrust {
    static let providerManifestMaxBytes = 64 * 1024
    static let snapshotMaxBytes = 1024 * 1024
    static let snapshotMaxEntries = 512
    static let destinationManifestMaxBytes = 256 * 1024
    /// `expiresAt − generatedAt` bound (§4.2): 90 days.
    static let snapshotMaxValiditySeconds: TimeInterval = 90 * 86_400

    // MARK: - Provider manifest

    /// Verify a provider manifest's exact published bytes (§6 "on
    /// adding a provider" + every refresh).
    ///
    /// - Parameters:
    ///   - raw: the bytes as served.
    ///   - pinnedOperatorKeyHex: the source's pinned key (64 lowercase
    ///     hex). `nil` means first add (TOFU): the manifest's own
    ///     `operator` key verifies the signature and is returned in
    ///     `SignedProviderManifest.operatorPublicKeyHex` for the caller
    ///     to pin after user confirmation. When non-nil, a manifest
    ///     naming any other key is `provider_manifest_invalid` — never
    ///     a silent rotation.
    ///   - now: injected clock for the `validUntil` check.
    public static func verifyProviderManifest(
        raw: Data,
        pinnedOperatorKeyHex: String?,
        now: Date
    ) throws -> SignedProviderManifest {
        guard raw.count <= providerManifestMaxBytes else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "manifest exceeds 64 KiB")
        }

        let manifest: DiscoveryProviderManifest
        do {
            manifest = try DiscoveryJSON.decoder().decode(DiscoveryProviderManifest.self, from: raw)
        } catch {
            throw DiscoveryTrustError.providerManifestInvalid(
                reason: "schema violation: \(shortDescription(of: error))"
            )
        }

        guard manifest.version == 1 else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "unsupported version \(manifest.version)")
        }
        guard manifest.implementationProfile == DiscoveryFormat.implementationProfile else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "unsupported implementation profile")
        }
        guard manifest.seat == "discovery" else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "seat is not \"discovery\"")
        }
        guard DiscoveryFormat.isComponentId(manifest.providerId) else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "malformed providerId")
        }
        guard let manifestKeyHex = DiscoveryFormat.operatorKeyHex(manifest.operatorKey) else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "malformed operator key")
        }

        guard !manifest.catalogs.isEmpty else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "catalogs is empty")
        }
        var seenCatalogIds = Set<String>()
        for catalog in manifest.catalogs {
            guard DiscoveryFormat.isCatalogId(catalog.catalogId) else {
                throw DiscoveryTrustError.providerManifestInvalid(reason: "malformed catalogId")
            }
            guard seenCatalogIds.insert(catalog.catalogId).inserted else {
                throw DiscoveryTrustError.providerManifestInvalid(
                    reason: "duplicate catalogId \(catalog.catalogId)"
                )
            }
            guard DiscoveryFormat.isValidURI(catalog.snapshot) else {
                throw DiscoveryTrustError.providerManifestInvalid(
                    reason: "catalog snapshot URI violates the profile URI rules"
                )
            }
            guard DiscoveryFormat.isDigest(catalog.policy) else {
                throw DiscoveryTrustError.providerManifestInvalid(reason: "malformed policy digest")
            }
            if let policyUri = catalog.policyUri {
                guard DiscoveryFormat.isValidURI(policyUri) else {
                    throw DiscoveryTrustError.providerManifestInvalid(
                        reason: "policyUri violates the profile URI rules"
                    )
                }
            }
        }
        if let privacyProfile = manifest.privacyProfile {
            guard DiscoveryFormat.isDigest(privacyProfile) else {
                throw DiscoveryTrustError.providerManifestInvalid(reason: "malformed privacyProfile digest")
            }
        }
        if let privacyProfileUri = manifest.privacyProfileUri {
            guard DiscoveryFormat.isValidURI(privacyProfileUri) else {
                throw DiscoveryTrustError.providerManifestInvalid(
                    reason: "privacyProfileUri violates the profile URI rules"
                )
            }
        }

        guard manifest.validUntil > now else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "validUntil is in the past")
        }

        // Key pinning (TOFU): once pinned, a manifest signed by — or
        // even just naming — a different key is invalid. Rotation
        // requires re-adding the source as new.
        if let pinnedOperatorKeyHex, pinnedOperatorKeyHex != manifestKeyHex {
            throw DiscoveryTrustError.providerManifestInvalid(
                reason: "operator key does not match the pinned key"
            )
        }

        try verifyEmbeddedSignature(
            raw: raw,
            signatureBase64: manifest.signature,
            operatorKeyHex: manifestKeyHex,
            invalid: { DiscoveryTrustError.providerManifestInvalid(reason: $0) }
        )

        return SignedProviderManifest(
            manifest: manifest,
            rawBytes: raw,
            manifestDigest: DiscoveryFormat.sha256Digest(of: raw),
            operatorPublicKeyHex: manifestKeyHex
        )
    }

    // MARK: - Catalog snapshot

    /// Verify a catalog snapshot's exact published bytes against its
    /// verified provider manifest and the previously accepted snapshot
    /// of the same catalog (§6 "on each refresh").
    ///
    /// - Parameters:
    ///   - raw: the snapshot bytes as served.
    ///   - manifest: the verified provider manifest the snapshot URL
    ///     came from; supplies the operator key, the expected
    ///     `providerId`, and the catalog's pinned `policy` digest.
    ///   - previousRaw: the exact retained bytes of the last accepted
    ///     snapshot for this catalog, or `nil` on first fetch (then the
    ///     snapshot must be `sequence` 1 with no `previousDigest`).
    ///     A sequence that does not advance by exactly 1, or a
    ///     `previousDigest` that does not hash the retained bytes, is
    ///     evidence of rollback or equivocation — `snapshot_invalid`,
    ///     never silently accepted.
    ///   - now: injected clock for the expiry checks.
    public static func verifySnapshot(
        raw: Data,
        manifest: SignedProviderManifest,
        previousRaw: Data?,
        now: Date
    ) throws -> SignedCatalogSnapshot {
        guard raw.count <= snapshotMaxBytes else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "snapshot exceeds 1 MiB")
        }

        let snapshot: CatalogSnapshot
        do {
            snapshot = try DiscoveryJSON.decoder().decode(CatalogSnapshot.self, from: raw)
        } catch {
            throw DiscoveryTrustError.snapshotInvalid(
                reason: "schema violation: \(shortDescription(of: error))"
            )
        }

        guard snapshot.version == 1 else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "unsupported version \(snapshot.version)")
        }
        guard snapshot.implementationProfile == DiscoveryFormat.implementationProfile else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "unsupported implementation profile")
        }
        guard snapshot.providerId == manifest.manifest.providerId else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "providerId does not match the manifest")
        }
        guard let descriptor = manifest.manifest.catalogs.first(where: { $0.catalogId == snapshot.catalogId }) else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "catalogId is not declared by the manifest")
        }
        guard snapshot.policyDigest == descriptor.policy else {
            throw DiscoveryTrustError.snapshotInvalid(
                reason: "policyDigest does not match the manifest's catalog descriptor"
            )
        }

        guard snapshot.expiresAt > now else {
            throw DiscoveryTrustError.snapshotExpired
        }
        guard snapshot.generatedAt <= snapshot.expiresAt,
              snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt) <= snapshotMaxValiditySeconds
        else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "expiresAt − generatedAt exceeds 90 days")
        }

        guard snapshot.entries.count + snapshot.skippedEntryCount <= snapshotMaxEntries else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "more than 512 entries")
        }
        var seenComponentIds = Set<String>()
        for entry in snapshot.entries {
            guard seenComponentIds.insert(entry.componentId).inserted else {
                throw DiscoveryTrustError.snapshotInvalid(
                    reason: "duplicate componentId \(entry.componentId)"
                )
            }
        }

        // Chain rules (§4.2): sequence starts at 1 and advances by
        // exactly 1; previousDigest hashes the previous snapshot's
        // exact retained bytes and is present iff sequence > 1.
        if let previousRaw {
            let previous: CatalogSnapshot
            do {
                previous = try DiscoveryJSON.decoder().decode(CatalogSnapshot.self, from: previousRaw)
            } catch {
                throw DiscoveryTrustError.snapshotInvalid(reason: "retained previous snapshot is unreadable")
            }
            guard previous.catalogId == snapshot.catalogId else {
                throw DiscoveryTrustError.snapshotInvalid(reason: "retained previous snapshot is for another catalog")
            }
            guard snapshot.sequence == previous.sequence + 1 else {
                throw DiscoveryTrustError.snapshotInvalid(
                    reason: "sequence \(snapshot.sequence) does not advance retained sequence \(previous.sequence) by 1 (rollback or gap)"
                )
            }
            guard let previousDigest = snapshot.previousDigest else {
                throw DiscoveryTrustError.snapshotInvalid(reason: "previousDigest is missing")
            }
            let retainedDigest = DiscoveryFormat.sha256Digest(of: previousRaw)
            guard previousDigest == retainedDigest else {
                throw DiscoveryTrustError.snapshotInvalid(
                    reason: "previousDigest does not match retained bytes (fork or equivocation)"
                )
            }
        } else {
            guard snapshot.sequence == 1 else {
                throw DiscoveryTrustError.snapshotInvalid(
                    reason: "first observed snapshot must have sequence 1, got \(snapshot.sequence)"
                )
            }
            guard snapshot.previousDigest == nil else {
                throw DiscoveryTrustError.snapshotInvalid(reason: "sequence 1 must not carry previousDigest")
            }
        }

        try verifyEmbeddedSignature(
            raw: raw,
            signatureBase64: snapshot.signature,
            operatorKeyHex: manifest.operatorPublicKeyHex,
            invalid: { DiscoveryTrustError.snapshotInvalid(reason: $0) }
        )

        return SignedCatalogSnapshot(
            snapshot: snapshot,
            rawBytes: raw,
            digest: DiscoveryFormat.sha256Digest(of: raw)
        )
    }

    // MARK: - Destination manifest

    /// Bind fetched destination-manifest bytes to the digest the
    /// provider reviewed (§6 "before presenting or selecting"). Bytes
    /// that hash differently are `entry_manifest_mismatch` — the entry
    /// is rejected, never refreshed by trusting bytes the provider did
    /// not review. Seat-specific signature/schema checks belong to the
    /// destination seat's own contract, applied after this.
    public static func verifyDestination(bytes: Data, pinnedDigest: String) throws {
        guard bytes.count <= destinationManifestMaxBytes else {
            throw DiscoveryTrustError.entryManifestUnavailable
        }
        guard DiscoveryFormat.isDigest(pinnedDigest) else {
            throw DiscoveryTrustError.entryManifestMismatch
        }
        guard DiscoveryFormat.sha256Digest(of: bytes) == pinnedDigest else {
            throw DiscoveryTrustError.entryManifestMismatch
        }
    }

    // MARK: - Shared

    /// Verify the document's embedded base64 signature (§3) over its
    /// canonical bytes against the given operator key. Accepts padded
    /// or unpadded base64 on read, per the profile.
    private static func verifyEmbeddedSignature(
        raw: Data,
        signatureBase64: String,
        operatorKeyHex: String,
        invalid: (String) -> DiscoveryTrustError
    ) throws {
        guard let keyData = Data(lowercaseHex: operatorKeyHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            throw invalid("operator key is not a valid Ed25519 public key")
        }
        guard let signature = decodeBase64AcceptingUnpadded(signatureBase64) else {
            throw invalid("signature is not valid base64")
        }
        let signingBytes: Data
        do {
            signingBytes = try DiscoveryCanonical.signingBytes(of: raw)
        } catch {
            throw invalid("document cannot be canonicalized")
        }
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: publicKey)
        guard verifier.isValid(signature: signature, for: signingBytes) else {
            throw invalid("signature does not verify against the operator key")
        }
    }

    static func decodeBase64AcceptingUnpadded(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) { return data }
        let remainder = value.count % 4
        guard remainder > 0 else { return nil }
        return Data(base64Encoded: value + String(repeating: "=", count: 4 - remainder))
    }

    private static func shortDescription(of error: Error) -> String {
        if case let DecodingError.dataCorrupted(context) = error {
            return context.debugDescription
        }
        return String(describing: error)
    }
}

extension Data {
    /// Strict lowercase-hex decode (the profile's key encoding).
    init?(lowercaseHex: String) {
        guard lowercaseHex.count % 2 == 0,
              DiscoveryFormat.isLowercaseHex(lowercaseHex)
        else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(lowercaseHex.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
