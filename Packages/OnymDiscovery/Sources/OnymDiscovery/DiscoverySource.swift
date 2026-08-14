import Foundation

/// Per-catalog record of the last snapshot this client accepted from a
/// source — enough, together with the retained bytes in the store, to
/// detect rollback and equivocation across refreshes (§8 of the
/// profile).
public struct AcceptedSnapshotRecord: Codable, Equatable, Hashable, Sendable {
    /// `sha256:<hex>` of the accepted snapshot's exact bytes.
    public let digest: String
    public let sequence: Int
    public let acceptedAt: Date
    /// The `policy` digest the manifest declared for this catalog at
    /// acceptance time — retained as the "immediately previous
    /// declaration" the §4.2 policy-transition grace accepts with a
    /// note on the next refresh. `nil` on records persisted by older
    /// builds.
    public let policyDigest: String?

    public init(digest: String, sequence: Int, acceptedAt: Date, policyDigest: String? = nil) {
        self.digest = digest
        self.sequence = sequence
        self.acceptedAt = acceptedAt
        self.policyDigest = policyDigest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        digest = try c.decode(String.self, forKey: .digest)
        sequence = try c.decode(Int.self, forKey: .sequence)
        acceptedAt = try c.decode(Date.self, forKey: .acceptedAt)
        policyDigest = try c.decodeIfPresent(String.self, forKey: .policyDigest)
    }

    private enum CodingKeys: String, CodingKey {
        case digest, sequence, acceptedAt, policyDigest
    }
}

/// One configured discovery provider. Identity is the operator key
/// behind `providerId`; the pinned key is set once at TOFU confirm and
/// never rotated in place (a manifest naming a different key fails
/// verification — re-adding the source is the rotation path).
public struct DiscoverySource: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// `onym:component:<id>` from the verified provider manifest.
    public let providerId: String
    /// Display label; defaults to the manifest URL's host at add time.
    public let userLabel: String
    public let manifestURL: URL
    /// 64-lowercase-hex Ed25519 operator key pinned at TOFU confirm.
    /// `nil` only for a seeded default the user has not yet confirmed —
    /// such a source is skipped on refresh until pinned.
    public let pinnedOperatorKeyHex: String?
    public let addedAt: Date
    public let isEnabled: Bool
    /// Last accepted snapshot per `catalogId`.
    public let lastAccepted: [String: AcceptedSnapshotRecord]

    public var id: String { providerId }

    /// Short human-checkable fingerprint of the pinned key for the
    /// TOFU confirmation screen: first 16 hex chars in groups of 4.
    public var operatorKeyFingerprint: String? {
        pinnedOperatorKeyHex.map { Self.fingerprint(ofKeyHex: $0) }
    }

    public static func fingerprint(ofKeyHex hex: String) -> String {
        stride(from: 0, to: min(hex.count, 16), by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(4, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    /// The Onym-operated default provider, seeded on first run only
    /// (see `DiscoverySourcesConfiguration`). Ships unpinned — the
    /// deployment is not live yet, and pinning happens through the
    /// same TOFU confirmation as any other source.
    public static let onymDefault = DiscoverySource(
        providerId: "onym:component:onym-discovery",
        userLabel: "Onym Discovery",
        manifestURL: URL(string: "https://discovery.onym.app/manifest.json")!,
        pinnedOperatorKeyHex: nil,
        addedAt: Date(timeIntervalSince1970: 0),
        isEnabled: true,
        lastAccepted: [:]
    )

    public init(
        providerId: String,
        userLabel: String,
        manifestURL: URL,
        pinnedOperatorKeyHex: String?,
        addedAt: Date,
        isEnabled: Bool = true,
        lastAccepted: [String: AcceptedSnapshotRecord] = [:]
    ) {
        self.providerId = providerId
        self.userLabel = userLabel
        self.manifestURL = manifestURL
        self.pinnedOperatorKeyHex = pinnedOperatorKeyHex
        self.addedAt = addedAt
        self.isEnabled = isEnabled
        self.lastAccepted = lastAccepted
    }

    /// Backward-compat decoder in the `RelayerEndpoint` style: fields
    /// added after first ship decode with safe defaults so a persisted
    /// configuration from an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try c.decode(String.self, forKey: .providerId)
        userLabel = try c.decode(String.self, forKey: .userLabel)
        manifestURL = try c.decode(URL.self, forKey: .manifestURL)
        pinnedOperatorKeyHex = try c.decodeIfPresent(String.self, forKey: .pinnedOperatorKeyHex)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastAccepted = try c.decodeIfPresent(
            [String: AcceptedSnapshotRecord].self,
            forKey: .lastAccepted
        ) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case providerId, userLabel, manifestURL, pinnedOperatorKeyHex
        case addedAt, isEnabled, lastAccepted
    }

    // MARK: - Non-mutating updates

    func withLastAccepted(_ record: AcceptedSnapshotRecord, forCatalog catalogId: String) -> DiscoverySource {
        var accepted = lastAccepted
        accepted[catalogId] = record
        return DiscoverySource(
            providerId: providerId,
            userLabel: userLabel,
            manifestURL: manifestURL,
            pinnedOperatorKeyHex: pinnedOperatorKeyHex,
            addedAt: addedAt,
            isEnabled: isEnabled,
            lastAccepted: accepted
        )
    }

    func withEnabled(_ enabled: Bool) -> DiscoverySource {
        DiscoverySource(
            providerId: providerId,
            userLabel: userLabel,
            manifestURL: manifestURL,
            pinnedOperatorKeyHex: pinnedOperatorKeyHex,
            addedAt: addedAt,
            isEnabled: enabled,
            lastAccepted: lastAccepted
        )
    }
}

/// The user's full discovery configuration. Mirrors
/// `RelayerConfiguration`'s interaction semantics:
///
/// - `hasUserInteracted` is `false` only on a cold install before the
///   default source is seeded; every mutation flips it `true`.
/// - `removedDefaultProviderIds` makes removal durable: a provider the
///   user removed is never silently restored by seeding or any future
///   default set (profile §8 / abstract §8). Explicitly re-adding a
///   source clears its entry.
public struct DiscoverySourcesConfiguration: Codable, Equatable, Sendable {
    public let sources: [DiscoverySource]
    public let removedDefaultProviderIds: Set<String>
    public let hasUserInteracted: Bool

    public static let empty = DiscoverySourcesConfiguration(
        sources: [],
        removedDefaultProviderIds: [],
        hasUserInteracted: false
    )

    public init(
        sources: [DiscoverySource],
        removedDefaultProviderIds: Set<String>,
        hasUserInteracted: Bool = true
    ) {
        self.sources = sources
        self.removedDefaultProviderIds = removedDefaultProviderIds
        self.hasUserInteracted = hasUserInteracted
    }

    /// Backward-compat: older saves may lack the newer fields. Absence
    /// of `hasUserInteracted` decodes as `true` (same reasoning as
    /// `RelayerConfiguration`: never re-seed over a configuration the
    /// user already touched).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decode([DiscoverySource].self, forKey: .sources)
        removedDefaultProviderIds = try c.decodeIfPresent(
            Set<String>.self,
            forKey: .removedDefaultProviderIds
        ) ?? []
        hasUserInteracted = try c.decodeIfPresent(Bool.self, forKey: .hasUserInteracted) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case sources, removedDefaultProviderIds, hasUserInteracted
    }
}
