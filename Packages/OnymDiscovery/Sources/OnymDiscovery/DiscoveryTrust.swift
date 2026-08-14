import Foundation
import CryptoKit
import OnymFoundation

/// Typed mirror of the profile's error table
/// (`Discovery-Static-Ed25519.md` §9 / `Discovery.md` §12). `reason`
/// strings are diagnostic, not part of the contract.
public enum DiscoveryTrustError: Error, Equatable, Sendable {
    /// Signature/key-pin failure, unknown top-level field, bad
    /// version/profile/seat, zero surviving catalog descriptors,
    /// expired `validUntil`, oversize, or URI violation in a provider
    /// manifest.
    case providerManifestInvalid(reason: String)
    /// Signature failure, sequence gap/repeat/rollback,
    /// `previousDigest` mismatch, duplicate `componentId`, unknown
    /// top-level field, or oversize in a snapshot.
    case snapshotInvalid(reason: String)
    /// `expiresAt` more than the 10-minute skew allowance in the past.
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
    /// §4.2/§9 clock-skew allowance on expiry: a snapshot is
    /// `snapshot_expired` only when `expiresAt` is more than this far
    /// in the past (a fast clock must not reject a fresh snapshot).
    static let clockSkewSeconds: TimeInterval = 10 * 60

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
        guard manifest.implementationProfileId == DiscoveryFormat.implementationProfileId else {
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

        // Descriptors decode lossily (§4.1): malformed ones were
        // skipped and counted at decode time. Zero DECODABLE
        // descriptors is fatal — audience-based skips (§1) do NOT
        // count toward invalidity: a manifest of decodable but
        // all-non-public catalogs is a valid, empty-by-policy source.
        guard !(manifest.catalogs.isEmpty && manifest.nonPublicCatalogs.isEmpty) else {
            throw DiscoveryTrustError.providerManifestInvalid(
                reason: "no surviving catalog descriptors"
            )
        }
        var seenCatalogIds = Set<String>()
        for catalog in manifest.catalogs + manifest.nonPublicCatalogs {
            guard seenCatalogIds.insert(catalog.catalogId).inserted else {
                throw DiscoveryTrustError.providerManifestInvalid(
                    reason: "duplicate catalogId \(catalog.catalogId)"
                )
            }
        }
        guard DiscoveryFormat.isDigest(manifest.privacyProfile) else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "malformed privacyProfile digest")
        }
        guard DiscoveryFormat.isValidURI(manifest.privacyProfileUri) else {
            throw DiscoveryTrustError.providerManifestInvalid(
                reason: "privacyProfileUri violates the profile URI rules"
            )
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
    /// verified provider manifest and the retained per-catalog
    /// acceptance state (§6 "on each refresh").
    ///
    /// - Parameters:
    ///   - raw: the snapshot bytes as served.
    ///   - manifest: the verified provider manifest the snapshot URL
    ///     came from; supplies the operator key, the expected
    ///     `providerId`, and the catalog's pinned `policy` digest.
    ///   - retained: the last acceptance retained for this catalog, or
    ///     `nil` on first acceptance of the source (any sequence is
    ///     accepted then — TOFU covers trust). §6's four cases apply
    ///     against it: a no-op refresh (same sequence, same bytes) is
    ///     fine; a rollback or fork is `snapshot_invalid`; a forward
    ///     jump is accepted with a source-integrity note.
    ///   - now: injected clock for the expiry checks.
    public static func verifySnapshot(
        raw: Data,
        manifest: SignedProviderManifest,
        retained: RetainedCatalogAcceptance?,
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
        guard snapshot.implementationProfileId == DiscoveryFormat.implementationProfileId else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "unsupported implementation profile")
        }
        guard snapshot.providerId == manifest.manifest.providerId else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "providerId does not match the manifest")
        }
        guard let descriptor = manifest.manifest.catalogs.first(where: { $0.catalogId == snapshot.catalogId }) else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "catalogId is not declared by the manifest")
        }
        // §4.2 policy-transition grace: the snapshot must cite the
        // manifest's current declaration OR the immediately previous
        // one the client retained — accepted with a surfaced
        // transition note. Any other digest is snapshot_invalid.
        var policyTransition = false
        if snapshot.policyDigest != descriptor.policy {
            if let previous = retained?.previousPolicyDigest, previous == snapshot.policyDigest {
                policyTransition = true
            } else {
                throw DiscoveryTrustError.snapshotInvalid(
                    reason: "policyDigest matches neither the manifest's pinned policy nor the retained previous declaration"
                )
            }
        }

        // §4.2: expiresAt must be STRICTLY after generatedAt (a
        // snapshot born expired — including generatedAt == expiresAt —
        // is snapshot_invalid), and the window is capped at 90 days.
        // Checked before the expiry evaluation so a born-expired
        // snapshot maps to snapshot_invalid, matching the reference
        // implementation's check order.
        guard snapshot.expiresAt > snapshot.generatedAt else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "expiresAt is not after generatedAt")
        }
        guard snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt) <= snapshotMaxValiditySeconds
        else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "expiresAt − generatedAt exceeds 90 days")
        }
        // §4.2: generatedAt must not lie in the verifier's future
        // beyond the skew allowance — otherwise the 90-day ceiling
        // could be minted forward.
        guard snapshot.generatedAt <= now.addingTimeInterval(clockSkewSeconds) else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "generatedAt is in the future")
        }
        // Expired only when expiresAt is more than the skew allowance
        // in the past (§4.2/§9 — symmetric 10-minute clock skew).
        guard snapshot.expiresAt.addingTimeInterval(clockSkewSeconds) >= now else {
            throw DiscoveryTrustError.snapshotExpired
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

        // Structural chain rules (§4.2): sequence starts at 1;
        // previousDigest is present (and digest-shaped) iff
        // sequence > 1.
        guard snapshot.sequence >= 1 else {
            throw DiscoveryTrustError.snapshotInvalid(reason: "sequence starts at 1")
        }
        if snapshot.sequence == 1 {
            guard snapshot.previousDigest == nil else {
                throw DiscoveryTrustError.snapshotInvalid(reason: "sequence 1 must not carry previousDigest")
            }
        } else {
            guard let previousDigest = snapshot.previousDigest,
                  DiscoveryFormat.isDigest(previousDigest)
            else {
                throw DiscoveryTrustError.snapshotInvalid(reason: "sequence > 1 requires previousDigest")
            }
        }

        // §6 four-case comparison against the retained acceptance.
        let digest = DiscoveryFormat.sha256Digest(of: raw)
        let outcome: SnapshotChainOutcome
        if let retained {
            if snapshot.sequence < retained.sequence {
                throw DiscoveryTrustError.snapshotInvalid(
                    reason: "rollback: sequence \(snapshot.sequence) after accepted \(retained.sequence)"
                )
            } else if snapshot.sequence == retained.sequence {
                guard digest == retained.digest else {
                    throw DiscoveryTrustError.snapshotInvalid(
                        reason: "fork: sequence \(snapshot.sequence) republished with different bytes"
                    )
                }
                outcome = .noOpRefresh
            } else if snapshot.sequence == retained.sequence + 1 {
                guard snapshot.previousDigest == retained.digest else {
                    throw DiscoveryTrustError.snapshotInvalid(
                        reason: "fork: previousDigest does not match the retained snapshot digest"
                    )
                }
                outcome = .successor
            } else {
                // Forward jump: accepted with a source-integrity note.
                // The §6 intermediate continuity walk is not
                // performed (gap-listed in the profile's §11).
                outcome = .forwardJump(missed: snapshot.sequence - retained.sequence - 1)
            }
        } else {
            // First acceptance of this catalog: any sequence — an
            // established catalog past its first snapshot must be
            // addable; TOFU covers trust.
            outcome = .firstAcceptance
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
            digest: digest,
            outcome: outcome,
            policyTransition: policyTransition
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
