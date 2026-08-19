import Foundation
import OnymFoundation

/// The backup-seat fields of an operator's signed service manifest.
///
/// `SignedServiceManifest` already carries and verifies the spine every
/// seat shares — component id, seat, operator key, offers, validity,
/// canonical signing bytes. This reads the `storage.backup` fields out of
/// the same verified `rawBytes` rather than re-fetching or re-deriving
/// them, so there is exactly one document under exactly one signature.
///
/// Spec: `UI-Backup.md` §5.3.
public struct BackupOperatorManifest: Sendable, Equatable {
    public let componentId: String
    public let operatorKey: String
    public let backupProfileId: String
    public let implementationProfileId: String
    /// Read-write HTTPS origin. Exactly one is supported today; a manifest
    /// offering several is not an error. We bind to the first read-write
    /// entry that is *usable* — https, with a host — skipping malformed
    /// ones rather than failing the manifest, and stay bound to it for
    /// the whole operation. A manifest whose read-write entries are all
    /// malformed is `invalidEndpoint`; we never rewrite one into
    /// something that works.
    public let endpoint: URL
    public let capabilities: Set<String>
    public let maximumSealedSnapshotBytes: Int?
    public let maximumRetainedSnapshots: Int?
    /// `sha256:<hex>` of the `BackupTerms` this manifest declares.
    public let declaredTermsDigest: String
    public let privacyProfile: String?
    /// Keys whose signature over a `SeatEntitlement` this operator will
    /// accept. Pinned from here — never from an entitlement response.
    public let entitlementIssuers: [String]
    public let offerIds: [String]
    public let manifestHash: String
    public let validUntil: Date?

    /// The seat value a backup operator must declare.
    public static let seat = "storage.backup"

    /// Read the backup fields from an already-verified manifest.
    ///
    /// Refusals are deliberately coarse. A manifest that is not a backup
    /// seat, that names a profile we do not implement, or that is missing
    /// a field this seat needs, all end the same way: this operator cannot
    /// be used, and no partially-populated value escapes to be checked
    /// later against a snapshot.
    public init(manifest: SignedServiceManifest) throws {
        guard manifest.seat == Self.seat else { throw BackupError.unsupportedProfile }
        guard let object = try? JSONSerialization.jsonObject(with: manifest.rawBytes) as? [String: Any] else {
            throw BackupError.unsupportedProfile
        }
        guard
            let backupProfileId = object["backupProfileId"] as? String,
            let implementationProfileId = object["implementationProfileId"] as? String,
            BackupProfile.supports(portableProfileId: backupProfileId),
            BackupProfile.supports(implementationProfileId: implementationProfileId)
        else {
            throw BackupError.unsupportedProfile
        }
        guard
            let declaredTermsDigest = object["declaredTerms"] as? String,
            BackupFormat.isDigest(declaredTermsDigest)
        else {
            throw BackupError.termsUnavailable
        }

        let endpoints = (object["endpoints"] as? [[String: Any]]) ?? []
        guard let endpoint = Self.readWriteEndpoint(from: endpoints) else {
            throw BackupError.invalidEndpoint
        }

        let capabilities = Set((object["capabilities"] as? [String]) ?? [])
        guard BackupProfile.requiredOperations.isSubset(of: capabilities) else {
            throw BackupError.unsupportedProfile
        }

        let limits = (object["limits"] as? [String: Any]) ?? [:]

        self.componentId = manifest.componentId
        self.operatorKey = manifest.operatorKey
        self.backupProfileId = backupProfileId
        self.implementationProfileId = implementationProfileId
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.maximumSealedSnapshotBytes = limits["maximumSealedSnapshotBytes"] as? Int
        self.maximumRetainedSnapshots = limits["maximumRetainedSnapshots"] as? Int
        self.declaredTermsDigest = declaredTermsDigest
        self.privacyProfile = object["privacyProfile"] as? String
        self.entitlementIssuers = (object["entitlementIssuers"] as? [String]) ?? []
        self.offerIds = manifest.offers.map(\.offerId)
        self.manifestHash = manifest.manifestHash
        self.validUntil = manifest.validUntil
    }

    /// An operator with no declared entitlement issuer never charges. That
    /// is the self-hosting path, and it is the same implementation — not a
    /// different build (`UI-Backup-Object-HTTP.md` §4.2).
    public var requiresEntitlement: Bool { !entitlementIssuers.isEmpty }

    /// Where this operator's content-addressed terms live.
    ///
    /// Requires a full `sha256:<64 hex>` digest rather than any hex
    /// string: this builds a URL we then fetch, and a short or
    /// over-long component would send a request for something that is
    /// not a terms document at all.
    public func termsURL(digest: String) -> URL? {
        let prefixed = digest.hasPrefix(BackupFormat.digestPrefix)
            ? digest
            : BackupFormat.digestPrefix + digest
        guard BackupFormat.isDigest(prefixed) else { return nil }
        let hex = String(prefixed.dropFirst(BackupFormat.digestPrefix.count))
        return endpoint.appending(path: "terms").appending(path: "\(hex).json")
    }

    private static func readWriteEndpoint(from endpoints: [[String: Any]]) -> URL? {
        for entry in endpoints where (entry["role"] as? String) == "read-write" {
            guard
                let uri = entry["uri"] as? String,
                let url = URL(string: uri),
                url.scheme?.lowercased() == "https",
                let host = url.host(), !host.isEmpty
            else {
                continue
            }
            return url
        }
        return nil
    }
}
