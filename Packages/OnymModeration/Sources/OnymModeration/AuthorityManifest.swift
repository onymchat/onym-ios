import Foundation
import CryptoKit

/// One violation class from an authority manifest, with the five
/// mandatory terms every class must declare (Moderation.md §5.2
/// normative constraint 1). A class missing any term fails decode,
/// which is exactly the spec's "invalid at mandate validation".
public struct ViolationClass: Codable, Sendable, Equatable {
    public let classId: String
    /// Content address (hash-or-url) of the exact prohibited-content
    /// definition the user consents to. Immutable once consented.
    public let definition: String
    public let responseWindow: ISO8601Duration
    public let decisionDeadline: ISO8601Duration
    public let banTerm: BanTerm
    public let appealWindow: ISO8601Duration
    public let appealEffect: AppealEffect
    /// Statutory reporting the authority performs for this class
    /// (declared for classes such as CSAM; absent elsewhere).
    public let lawfulReporting: String?

    public init(
        classId: String,
        definition: String,
        responseWindow: ISO8601Duration,
        decisionDeadline: ISO8601Duration,
        banTerm: BanTerm,
        appealWindow: ISO8601Duration,
        appealEffect: AppealEffect,
        lawfulReporting: String? = nil
    ) {
        self.classId = classId
        self.definition = definition
        self.responseWindow = responseWindow
        self.decisionDeadline = decisionDeadline
        self.banTerm = banTerm
        self.appealWindow = appealWindow
        self.appealEffect = appealEffect
        self.lawfulReporting = lawfulReporting
    }
}

/// A moderation authority's published, signed manifest (Moderation.md
/// §5.2): the complete enumeration of its power. Everything the user
/// consents to at mandate signing is in here or content-addressed
/// from here.
public struct AuthorityManifest: Codable, Sendable, Equatable {
    public let version: Int
    /// `onym:component:<authority-id>` — the authority's identity in
    /// mandates and verdicts.
    public let componentId: String
    public let seat: String
    /// `onym:key:<authority-identity>` — the verdict/manifest signing
    /// key. `operator` is the spec's field name.
    public let operatorKey: String
    public let moderationProfileId: String
    public let violationClasses: [ViolationClass]
    public let evidenceRules: String?
    public let reputationPolicy: String?
    /// Procedure for a device's new owner — surfaced in the ban UX
    /// (a mandatory appeal class, spec §5.7).
    public let newHolderAppeal: String?
    /// External appellate authority, or `"self"` for manifests with no
    /// permanent class (spec §5.2 constraint 2).
    public let appellate: String?
    public let confidentiality: String?
    public let statistics: String?
    public let offers: [String]?
    /// Bounds new mandates and new cases, not live process.
    public let validUntil: Date
    /// Authority signature over the manifest. Verified against the
    /// directory-pinned operator key (see `AuthorityManifestFetcher`).
    public let signature: String

    enum CodingKeys: String, CodingKey {
        case version, componentId, seat
        case operatorKey = "operator"
        case moderationProfileId, violationClasses, evidenceRules
        case reputationPolicy, newHolderAppeal, appellate
        case confidentiality, statistics, offers, validUntil, signature
    }

    public func violationClass(id: String) -> ViolationClass? {
        violationClasses.first { $0.classId == id }
    }
}

/// The unit of consent: a decoded manifest together with the exact
/// bytes it was fetched as. `manifestHash` — SHA-256 over those exact
/// bytes — is what the mandate pins.
///
/// Hashing the fetched bytes rather than a canonical re-encoding is
/// deliberate: the draft spec defines no canonical JSON, hashing exact
/// bytes matches the repo's `SignedAsset` model (signatures over exact
/// bytes), and persisting `rawBytes` alongside the mandate keeps the
/// consented terms displayable and re-verifiable even if the authority
/// later edits the hosted file or disappears.
public struct SignedManifest: Sendable, Equatable {
    public let manifest: AuthorityManifest
    public let rawBytes: Data
    /// Lowercase hex SHA-256 of `rawBytes`.
    public let manifestHash: String

    public init(manifest: AuthorityManifest, rawBytes: Data) {
        self.manifest = manifest
        self.rawBytes = rawBytes
        self.manifestHash = Self.hash(of: rawBytes)
    }

    public static func hash(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
