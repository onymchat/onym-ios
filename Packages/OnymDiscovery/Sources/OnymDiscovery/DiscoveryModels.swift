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
///   in OnymModeration).

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
    public let catalogs: [CatalogDescriptor]
    public let capabilities: [String]
    public let privacyProfile: String?
    public let privacyProfileUri: String?
    public let offers: [DiscoveryOffer]
    public let validUntil: Date
    public let signature: String

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
        catalogs = try c.decode([CatalogDescriptor].self, forKey: .catalogs)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        privacyProfile = try c.decodeIfPresent(String.self, forKey: .privacyProfile)
        privacyProfileUri = try c.decodeIfPresent(String.self, forKey: .privacyProfileUri)
        offers = try c.decode([DiscoveryOffer].self, forKey: .offers)
        validUntil = try c.decode(Date.self, forKey: .validUntil)
        signature = try c.decode(String.self, forKey: .signature)
    }
}

/// One catalog declared by a provider manifest (§4.1 `catalogs[]`).
public struct CatalogDescriptor: Decodable, Equatable, Sendable {
    /// `[a-z0-9-]{1,64}`, unique within the manifest.
    public let catalogId: String
    /// HTTPS URL of the snapshot file. Kept as the wire string; the
    /// URI rules of §7 are enforced by `DiscoveryTrust`, and
    /// `snapshotURL` projects it for fetching.
    public let snapshot: String
    public let audience: String
    public let seatTypes: [String]
    /// `sha256:<hex>` over the policy document's exact bytes. Every
    /// snapshot of this catalog must carry the same digest as its
    /// `policyDigest`.
    public let policy: String
    public let policyUri: String?

    public var snapshotURL: URL? { URL(string: snapshot) }
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
    public let profiles: [String]
    public let evidence: [EvidenceRef]
    public let listedAt: Date
    public let reviewedAt: Date?
    /// Abstract contract's relationship set (e.g. `common-owner`).
    /// Kept as the wire string — an entry with an *absent* value is
    /// skipped (never defaulted), but unknown future values pass
    /// through for the UI to disclose verbatim.
    public let relationship: String
    public let placement: String

    static let allowedKeys: Set<String> = [
        "componentId", "seatType", "manifest", "operator", "profiles",
        "evidence", "listedAt", "reviewedAt", "relationship", "placement",
    ]

    private enum CodingKeys: String, CodingKey {
        case componentId, seatType, manifest
        case operatorKey = "operator"
        case profiles, evidence, listedAt, reviewedAt, relationship, placement
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
        profiles = try c.decode([String].self, forKey: .profiles)
        evidence = try c.decode([EvidenceRef].self, forKey: .evidence)
        listedAt = try c.decode(Date.self, forKey: .listedAt)
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
        relationship = try c.decode(String.self, forKey: .relationship)
        placement = try c.decode(String.self, forKey: .placement)
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

    init(snapshot: CatalogSnapshot, rawBytes: Data, digest: String) {
        self.snapshot = snapshot
        self.rawBytes = rawBytes
        self.digest = digest
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

    /// §7 URI rules: https only, DNS host (no IP literal), no
    /// userinfo, no query, no fragment, no explicit port.
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
