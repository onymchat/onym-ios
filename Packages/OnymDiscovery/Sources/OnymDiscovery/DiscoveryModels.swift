import Foundation
import CryptoKit
import os.log

/// Wire models for the Discovery seat's static-snapshot / Ed25519
/// implementation profile (`Discovery-Static-Ed25519.md` §4).
///
/// Decode-only by design: verified documents are always retained as
/// their exact published bytes (`SignedProviderManifest.rawBytes` /
/// `SignedCatalogSnapshot.rawBytes`), because every digest and
/// signature in the profile is over exact bytes, never over a
/// re-serialization. Making these types `Encodable` would invite
/// producing near-miss bytes that hash differently.
///
/// Decoding strictness follows the profile:
/// - **top-level** unknown fields in a provider manifest or snapshot
///   are rejected (`provider_manifest_invalid` / `snapshot_invalid`);
/// - **per-entry** unknown fields cause only that `CatalogEntry` to be
///   skipped (lossy entry decoding, modeled on `LossyAuthorityListing`
///   in OnymModeration);
/// - **per-descriptor** unknown fields (or an otherwise malformed
///   descriptor) cause only that `catalogs[]` descriptor to be skipped
///   and counted (§4.1); a manifest with zero surviving descriptors is
///   `provider_manifest_invalid`.

// MARK: - Provider manifest

/// §4.1 provider manifest. Signed by the operator key it names.
public struct DiscoveryProviderManifest: Decodable, Equatable, Sendable {
    public let version: Int
    public let implementationProfileId: String
    public let providerId: String
    /// `onym:key:<64-lowercase-hex Ed25519 public key>`. Property named
    /// `operatorKey` because `operator` is a Swift keyword.
    public let operatorKey: String
    public let seat: String
    /// Descriptors that survived lossy per-descriptor decoding (§4.1)
    /// AND whose `audience` is exactly `"public"`. Malformed
    /// descriptors are skipped, not defaulted
    /// (`skippedCatalogCount` says how many).
    public let catalogs: [CatalogDescriptor]
    /// Descriptors that decoded but whose `audience` is not exactly
    /// `"public"` — skipped per §1 (this profile serves public
    /// catalogs only), surfaced via `audienceSkippedCatalogCount`, and
    /// NOT counted toward manifest invalidity: a manifest of decodable
    /// but all-non-public catalogs is a valid, empty-by-policy source.
    public let nonPublicCatalogs: [CatalogDescriptor]
    public let capabilities: [String]
    public let privacyProfile: String
    public let privacyProfileUri: String
    public let offers: [DiscoveryOffer]
    public let validUntil: Date
    public let signature: String
    /// How many `catalogs[]` descriptors failed lossy decoding and were
    /// dropped. Not a wire field — surfaced so a manifest whose
    /// catalogs were partly skipped never reads as the whole set.
    public let skippedCatalogCount: Int
    /// How many decodable descriptors were skipped for a non-public
    /// `audience` (§1). Surfaced separately so an empty-by-policy
    /// source never reads as a silently empty one.
    public var audienceSkippedCatalogCount: Int { nonPublicCatalogs.count }

    /// The exact key set a conforming manifest may carry at top level.
    static let allowedTopLevelKeys: Set<String> = [
        "version", "implementationProfileId", "providerId", "operator",
        "seat", "catalogs", "capabilities", "privacyProfile",
        "privacyProfileUri", "offers", "validUntil", "signature",
    ]

    private enum CodingKeys: String, CodingKey {
        case version, implementationProfileId, providerId
        case operatorKey = "operator"
        case seat, catalogs, capabilities, privacyProfile
        case privacyProfileUri, offers, validUntil, signature
    }

    public init(from decoder: Decoder) throws {
        // Strict top-level decode: any key outside the profile's schema
        // rejects the whole manifest (§4: unknown top-level fields are
        // `provider_manifest_invalid`).
        let probe = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = Set(probe.allKeys.map(\.stringValue))
            .subtracting(Self.allowedTopLevelKeys)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown top-level fields: \(unknown.sorted().joined(separator: ", "))"
            ))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        implementationProfileId = try c.decode(String.self, forKey: .implementationProfileId)
        providerId = try c.decode(String.self, forKey: .providerId)
        operatorKey = try c.decode(String.self, forKey: .operatorKey)
        seat = try c.decode(String.self, forKey: .seat)
        let lossyCatalogs = try c.decode([LossyCatalogDescriptor].self, forKey: .catalogs)
        let decoded = lossyCatalogs.compactMap(\.value)
        catalogs = decoded.filter { $0.audience == "public" }
        nonPublicCatalogs = decoded.filter { $0.audience != "public" }
        skippedCatalogCount = lossyCatalogs.count - decoded.count
        capabilities = try c.decode([String].self, forKey: .capabilities)
        privacyProfile = try c.decode(String.self, forKey: .privacyProfile)
        privacyProfileUri = try c.decode(String.self, forKey: .privacyProfileUri)
        offers = try c.decode([DiscoveryOffer].self, forKey: .offers)
        validUntil = try c.decode(Date.self, forKey: .validUntil)
        signature = try c.decode(String.self, forKey: .signature)
    }
}

/// One catalog declared by a provider manifest (§4.1 `catalogs[]`).
/// Decoding is strict *within* the descriptor — an unknown field, a
/// malformed id/URI, or a bad digest fails this descriptor — but the
/// failure is absorbed by `LossyCatalogDescriptor`, skipping just this
/// descriptor.
public struct CatalogDescriptor: Decodable, Equatable, Sendable {
    /// `[a-z0-9-]{1,64}`, unique within the manifest.
    public let catalogId: String
    /// HTTPS URL of the snapshot file. Kept as the wire string;
    /// `snapshotURL` projects it for fetching.
    public let snapshot: String
    public let audience: String
    public let seatTypes: [String]
    /// `sha256:<hex>` over the policy document's exact bytes. Every
    /// snapshot of this catalog must carry the same digest as its
    /// `policyDigest`.
    public let policy: String
    public let policyUri: String

    public var snapshotURL: URL? { URL(string: snapshot) }

    static let allowedKeys: Set<String> = [
        "catalogId", "snapshot", "audience", "seatTypes", "policy", "policyUri",
    ]

    private enum CodingKeys: String, CodingKey {
        case catalogId, snapshot, audience, seatTypes, policy, policyUri
    }

    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = Set(probe.allKeys.map(\.stringValue))
            .subtracting(Self.allowedKeys)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown descriptor fields: \(unknown.sorted().joined(separator: ", "))"
            ))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalogId = try c.decode(String.self, forKey: .catalogId)
        snapshot = try c.decode(String.self, forKey: .snapshot)
        audience = try c.decode(String.self, forKey: .audience)
        seatTypes = try c.decode([String].self, forKey: .seatTypes)
        policy = try c.decode(String.self, forKey: .policy)
        policyUri = try c.decode(String.self, forKey: .policyUri)
        // Field-format checks that make a descriptor unusable: a bad
        // catalog id, a non-conforming snapshot/policy URI, or a
        // malformed policy digest — the descriptor is skipped at
        // decode time (§4.1), never document-fatal.
        guard DiscoveryFormat.isCatalogId(catalogId) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "malformed catalogId"
            ))
        }
        guard DiscoveryFormat.isValidURI(snapshot) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "catalog snapshot URI violates the profile URI rules"
            ))
        }
        guard DiscoveryFormat.isDigest(policy) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "malformed policy digest"
            ))
        }
        guard DiscoveryFormat.isValidURI(policyUri) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "policyUri violates the profile URI rules"
            ))
        }
        // §4.1: seatTypes members are seat-type tokens
        // (`[a-z0-9.-]{1,64}`) or the literal `"*"` wildcard, which
        // must appear alone. A member matching neither form skips the
        // descriptor (one lossiness model per level).
        for member in seatTypes where !DiscoveryFormat.isSeatTypeMember(member) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "invalid seatTypes member"
            ))
        }
        if seatTypes.contains("*"), seatTypes.count > 1 {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\"*\" must appear alone in seatTypes"
            ))
        }
    }
}

/// Lossy wrapper for `CatalogDescriptor` — same pattern as
/// `LossyCatalogEntry`: a malformed descriptor decodes to `nil` (and
/// logs) instead of sinking the provider manifest.
struct LossyCatalogDescriptor: Decodable {
    private static let log = Logger(
        subsystem: "app.onym.ios",
        category: "Discovery"
    )

    let value: CatalogDescriptor?

    init(from decoder: Decoder) throws {
        do {
            value = try CatalogDescriptor(from: decoder)
        } catch {
            let catalogId = (try? decoder.container(keyedBy: DiagnosticKeys.self))
                .flatMap { try? $0.decodeIfPresent(String.self, forKey: .catalogId) }
                ?? "<unknown>"
            Self.log.error(
                "Skipping malformed catalog descriptor \(catalogId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            value = nil
        }
    }

    private enum DiagnosticKeys: String, CodingKey {
        case catalogId
    }
}

/// Minimal offer shape. The full offers model lands with the
/// generalized consent work (OnymFoundation `ServiceOffer`); discovery
/// only needs to carry these through, so every field is optional and
/// unknown fields are tolerated.
public struct DiscoveryOffer: Decodable, Equatable, Sendable {
    public let offerId: String?
    public let model: String?
}

// MARK: - Catalog snapshot

/// §4.2 catalog snapshot. Signed by the same operator key as the
/// provider manifest that declared it.
public struct CatalogSnapshot: Decodable, Equatable, Sendable {
    public let version: Int
    public let implementationProfileId: String
    public let catalogId: String
    public let providerId: String
    /// Starts at 1; increases by exactly 1 per published snapshot.
    public let sequence: Int
    /// `sha256:<hex>` of the previous snapshot's exact published
    /// bytes; omitted only when `sequence` is 1.
    public let previousDigest: String?
    public let policyDigest: String
    public let generatedAt: Date
    public let expiresAt: Date
    /// Valid entries in provider policy-rank order. Malformed entries
    /// are skipped, not defaulted (`skippedEntryCount` says how many).
    public let entries: [CatalogEntry]
    public let signature: String
    /// How many entries failed lossy decoding and were dropped. Not a
    /// wire field.
    public let skippedEntryCount: Int

    static let allowedTopLevelKeys: Set<String> = [
        "version", "implementationProfileId", "catalogId", "providerId",
        "sequence", "previousDigest", "policyDigest", "generatedAt",
        "expiresAt", "entries", "signature",
    ]

    private enum CodingKeys: String, CodingKey {
        case version, implementationProfileId, catalogId, providerId
        case sequence, previousDigest, policyDigest, generatedAt
        case expiresAt, entries, signature
    }

    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = Set(probe.allKeys.map(\.stringValue))
            .subtracting(Self.allowedTopLevelKeys)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown top-level fields: \(unknown.sorted().joined(separator: ", "))"
            ))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        implementationProfileId = try c.decode(String.self, forKey: .implementationProfileId)
        catalogId = try c.decode(String.self, forKey: .catalogId)
        providerId = try c.decode(String.self, forKey: .providerId)
        sequence = try c.decode(Int.self, forKey: .sequence)
        previousDigest = try c.decodeIfPresent(String.self, forKey: .previousDigest)
        policyDigest = try c.decode(String.self, forKey: .policyDigest)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        let lossy = try c.decode([LossyCatalogEntry].self, forKey: .entries)
        entries = lossy.compactMap(\.value)
        skippedEntryCount = lossy.count - entries.count
        signature = try c.decode(String.self, forKey: .signature)
    }
}

/// One catalog entry (§4.2 `entries[]`). Decoding is strict *within*
/// the entry — an unknown field, a bad URI, or an undecodable
/// `relationship`/`placement` fails this entry — but the failure is
/// absorbed by `LossyCatalogEntry`, skipping just this entry.
public struct CatalogEntry: Decodable, Equatable, Sendable {
    public let componentId: String
    public let seatType: String
    public let manifest: ManifestRef
    /// Destination operator key, repeated for indexing; the fetched
    /// destination manifest remains authoritative.
    public let operatorKey: String
    /// §4.1 lists `profiles` and `evidence` as optional: a minimal
    /// conforming entry omits both, and must not be skipped for it.
    public let profiles: [String]
    /// §4.2: must be absent or the empty array in v1 — always empty
    /// here, because a non-empty `evidence` skips the entry (an
    /// unrenderable attestation is the audit-laundering the abstract
    /// §13 forbids presenting).
    public let evidence: [EvidenceRef]
    public let listedAt: Date
    public let reviewedAt: Date?
    /// The profile pins the accepted relationship set inline (§4.2)
    /// and deliberately **fails closed** against the abstract
    /// contract's extensibility: an entry with an unknown
    /// `relationship` is skipped rather than defaulted, because a
    /// commercial disclosure the client cannot render is a disclosure
    /// the user never saw.
    public let relationship: String
    public let placement: String
    /// §4.2 disclosed warning/review status — defined in v1 so
    /// entry-lossy decoding cannot silently drop the very entries
    /// carrying warnings. A VALID status never skips the entry; an
    /// undecodable one skips it like any other malformed field.
    public let status: EntryStatus?

    static let allowedKeys: Set<String> = [
        "componentId", "seatType", "manifest", "operator", "profiles",
        "evidence", "listedAt", "reviewedAt", "relationship", "placement",
        "status",
    ]

    private enum CodingKeys: String, CodingKey {
        case componentId, seatType, manifest
        case operatorKey = "operator"
        case profiles, evidence, listedAt, reviewedAt, relationship, placement
        case status
    }

    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = Set(probe.allKeys.map(\.stringValue))
            .subtracting(Self.allowedKeys)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown entry fields: \(unknown.sorted().joined(separator: ", "))"
            ))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        componentId = try c.decode(String.self, forKey: .componentId)
        seatType = try c.decode(String.self, forKey: .seatType)
        manifest = try c.decode(ManifestRef.self, forKey: .manifest)
        operatorKey = try c.decode(String.self, forKey: .operatorKey)
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        evidence = try c.decodeIfPresent([EvidenceRef].self, forKey: .evidence) ?? []
        listedAt = try c.decode(Date.self, forKey: .listedAt)
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
        relationship = try c.decode(String.self, forKey: .relationship)
        placement = try c.decode(String.self, forKey: .placement)
        status = try c.decodeIfPresent(EntryStatus.self, forKey: .status)
        // Field-format checks that make an entry unusable: a non-HTTPS
        // manifest URI or a malformed digest can never be fetched /
        // verified, so the entry is skipped at decode time.
        guard DiscoveryFormat.isValidURI(manifest.uri) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "entry manifest.uri violates the profile URI rules"
            ))
        }
        guard DiscoveryFormat.isDigest(manifest.digest) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "entry manifest.digest is not sha256:<64-hex>"
            ))
        }
        // §4.2 fail-closed rules: unknown relationship or undecodable
        // placement skips the entry — never a verbatim pass-through.
        guard DiscoveryFormat.relationships.contains(relationship) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown relationship"
            ))
        }
        guard !placement.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "empty placement"
            ))
        }
        // §4.2: non-empty evidence is deferred to v2; the entry is
        // skipped, never passed through as an unrenderable attestation.
        guard evidence.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "non-empty evidence in v1"
            ))
        }
    }
}

/// §4.2 entry `status`: `{"state": "warning" | "review", "uri"?}`.
/// Strictly decoded — any other shape or state skips the carrying
/// entry — but a valid value is surfaced, never dropped.
public struct EntryStatus: Decodable, Equatable, Hashable, Sendable {
    public let state: String
    public let uri: String?

    static let allowedKeys: Set<String> = ["state", "uri"]
    static let allowedStates: Set<String> = ["warning", "review"]

    private enum CodingKeys: String, CodingKey {
        case state, uri
    }

    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = Set(probe.allKeys.map(\.stringValue))
            .subtracting(Self.allowedKeys)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown status fields"
            ))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        uri = try c.decodeIfPresent(String.self, forKey: .uri)
        guard Self.allowedStates.contains(state) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown status state"
            ))
        }
        if let uri {
            guard DiscoveryFormat.isValidURI(uri) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "status uri violates the profile URI rules"
                ))
            }
        }
    }
}

/// Reference to a destination seat manifest: where to fetch it and the
/// digest of the exact bytes the provider reviewed.
public struct ManifestRef: Decodable, Equatable, Sendable {
    public let uri: String
    /// `sha256:<64-lowercase-hex>` over the destination manifest's
    /// exact published bytes.
    public let digest: String

    public var url: URL? { URL(string: uri) }
}

/// Evidence attachment on an entry. Shapes vary by evidence kind, so
/// every field is optional; fixtures currently publish empty arrays.
public struct EvidenceRef: Decodable, Equatable, Sendable {
    public let type: String?
    public let uri: String?
    public let digest: String?
}

/// Lossy wrapper for `CatalogEntry` — same pattern as
/// `LossyAuthorityListing` in OnymModeration: a malformed entry
/// decodes to `nil` (and logs) instead of sinking the snapshot.
struct LossyCatalogEntry: Decodable {
    private static let log = Logger(
        subsystem: "app.onym.ios",
        category: "Discovery"
    )

    let value: CatalogEntry?

    init(from decoder: Decoder) throws {
        do {
            value = try CatalogEntry(from: decoder)
        } catch {
            let componentId = (try? decoder.container(keyedBy: DiagnosticKeys.self))
                .flatMap { try? $0.decodeIfPresent(String.self, forKey: .componentId) }
                ?? "<unknown>"
            Self.log.error(
                "Skipping malformed catalog entry \(componentId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            value = nil
        }
    }

    private enum DiagnosticKeys: String, CodingKey {
        case componentId
    }
}

// MARK: - Verified wrappers

/// A provider manifest that passed `DiscoveryTrust.verifyProviderManifest`,
/// carrying the exact published bytes alongside the decoded form — the
/// same discipline as `SignedManifest` in OnymModeration. Constructed
/// only by `DiscoveryTrust`.
public struct SignedProviderManifest: Sendable {
    public let manifest: DiscoveryProviderManifest
    /// The exact bytes as served; digests over this document are over
    /// these bytes, never over a re-serialization.
    public let rawBytes: Data
    /// `sha256:<hex>` of `rawBytes`.
    public let manifestDigest: String
    /// The 64-lowercase-hex Ed25519 public key the signature verified
    /// against. On first add (TOFU, no pinned key) this is the
    /// manifest's own `operator` key — the caller pins it after user
    /// confirmation.
    public let operatorPublicKeyHex: String

    init(
        manifest: DiscoveryProviderManifest,
        rawBytes: Data,
        manifestDigest: String,
        operatorPublicKeyHex: String
    ) {
        self.manifest = manifest
        self.rawBytes = rawBytes
        self.manifestDigest = manifestDigest
        self.operatorPublicKeyHex = operatorPublicKeyHex
    }
}

/// §6's four-case chain comparison outcome for an ACCEPTED snapshot
/// (rollback and fork are rejections, not outcomes).
public enum SnapshotChainOutcome: Equatable, Sendable {
    /// No retained acceptance for this catalog: first acceptance. Any
    /// sequence is accepted — TOFU pinning covers trust, and an
    /// established catalog past its first snapshot must be addable.
    case firstAcceptance
    /// `sequence` = retained + 1 with a matching `previousDigest`.
    case successor
    /// Same sequence, same bytes — the provider simply hasn't
    /// published since. No warning.
    case noOpRefresh
    /// `sequence` more than retained + 1: accepted with a
    /// source-integrity note (§6). The intermediate-fetch continuity
    /// walk is not performed (gap-listed in the profile's §11).
    case forwardJump(missed: Int)
}

/// What the client retains per catalog between refreshes (§8): the
/// last accepted snapshot's sequence and digest, plus the catalog's
/// previously declared policy digest (the §4.2 one-generation
/// transition grace).
public struct RetainedCatalogAcceptance: Equatable, Sendable {
    public let sequence: Int
    /// `sha256:<hex>` of the last accepted snapshot's exact bytes.
    public let digest: String
    /// The `policy` digest the manifest declared for this catalog at
    /// the last acceptance — the "immediately previous declaration"
    /// §4.2's transition grace accepts with a note.
    public let previousPolicyDigest: String?

    public init(sequence: Int, digest: String, previousPolicyDigest: String?) {
        self.sequence = sequence
        self.digest = digest
        self.previousPolicyDigest = previousPolicyDigest
    }
}

/// A catalog snapshot that passed `DiscoveryTrust.verifySnapshot`.
/// Constructed only by `DiscoveryTrust`.
public struct SignedCatalogSnapshot: Sendable {
    public let snapshot: CatalogSnapshot
    /// The exact bytes as served — retained for the next refresh's
    /// `previousDigest` chain check.
    public let rawBytes: Data
    /// `sha256:<hex>` of `rawBytes` — the next snapshot's expected
    /// `previousDigest`.
    public let digest: String
    /// How this acceptance relates to the retained chain state (§6).
    public let outcome: SnapshotChainOutcome
    /// True when `policyDigest` matched the retained PREVIOUS policy
    /// declaration rather than the manifest's current one — accepted
    /// with a surfaced policy-transition note (§4.2).
    public let policyTransition: Bool

    init(
        snapshot: CatalogSnapshot,
        rawBytes: Data,
        digest: String,
        outcome: SnapshotChainOutcome,
        policyTransition: Bool
    ) {
        self.snapshot = snapshot
        self.rawBytes = rawBytes
        self.digest = digest
        self.outcome = outcome
        self.policyTransition = policyTransition
    }
}

// MARK: - Shared decode plumbing

/// One JSON decode configuration for every discovery document.
/// Timestamps are RFC 3339 UTC at second precision (§2); the
/// fractional fallback mirrors `ModerationJSON` for tolerance on read.
enum DiscoveryJSON {
    private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = wholeSeconds.date(from: value) ?? fractional.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected an RFC 3339 timestamp"
            )
        }
        return decoder
    }
}

/// Free-form coding key used to enumerate a container's actual keys
/// for strict-schema checks.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Format rules

/// Identifier / digest / URI syntax from §2 and §7 of the profile.
enum DiscoveryFormat {
    static let implementationProfileId = "onym:discovery-implementation:static-ed25519-v1"

    /// `onym:key:<64-lowercase-hex>` → the hex, or nil.
    static func operatorKeyHex(_ value: String) -> String? {
        guard value.hasPrefix("onym:key:") else { return nil }
        let hex = String(value.dropFirst("onym:key:".count))
        guard hex.count == 64, isLowercaseHex(hex) else { return nil }
        return hex
    }

    /// `onym:component:<[a-z0-9-]{1,64}>`.
    static func isComponentId(_ value: String) -> Bool {
        guard value.hasPrefix("onym:component:") else { return false }
        let id = value.dropFirst("onym:component:".count)
        return isCatalogId(String(id))
    }

    /// `[a-z0-9-]{1,64}`.
    static func isCatalogId(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// `sha256:` + 64 lowercase hex.
    static func isDigest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = String(value.dropFirst("sha256:".count))
        return hex.count == 64 && isLowercaseHex(hex)
    }

    /// The accepted `relationship` values for this profile version
    /// (§4.2) — pinned inline, deliberately fail-closed.
    static let relationships: Set<String> = [
        "none", "catalog-subscriber", "listing-fee", "sponsored-placement",
        "common-owner", "catalog-sponsor", "other-disclosed",
    ]

    /// §4.1 `seatTypes` member: a token in `[a-z0-9.-]{1,64}` or the
    /// literal `"*"` wildcard (whose must-appear-alone rule the caller
    /// enforces over the whole array).
    static func isSeatTypeMember(_ value: String) -> Bool {
        if value == "*" { return true }
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-"
        }
    }

    /// §7 URI rules: https only, DNS host (no IP literal, including
    /// integer/hex single-label forms), no userinfo, no query, no
    /// fragment, no port component in the **raw string** (URL
    /// libraries normalize a redundant `:443` away before any
    /// parsed-port check is reachable, so the raw string is checked
    /// directly).
    static func isValidURI(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        guard components.scheme == "https" else { return false }
        guard components.user == nil, components.password == nil else { return false }
        guard components.query == nil, components.fragment == nil else { return false }
        guard components.port == nil else { return false }
        guard let host = components.host, !host.isEmpty else { return false }
        // IPv6 literals surface as bracket-stripped hosts containing
        // ":"; IPv4 literals are four dot-separated decimal octets.
        if host.contains(":") { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return false
        }
        // Integer-form and hex-form IPv4 literals: a host whose LAST
        // label is all digits or 0x-prefixed is an IPv4 candidate per
        // the URL host parser, never a DNS name (TLDs are not numeric).
        if let last = parts.last {
            if !last.isEmpty, last.allSatisfy(\.isNumber) { return false }
            if last.lowercased().hasPrefix("0x") { return false }
        }
        // §7 raw-string port check.
        guard let schemeRange = value.range(of: "://") else { return false }
        let afterScheme = value[schemeRange.upperBound...]
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // Userinfo is rejected above; anything after the last "@" is
        // host[:port].
        let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? authority
        if hostPort.contains(":") { return false }
        return true
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// `sha256:<hex>` over exact bytes.
    static func sha256Digest(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
