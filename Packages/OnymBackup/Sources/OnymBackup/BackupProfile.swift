import Foundation

/// The profile identifiers this client implements.
///
/// A backup operator publishes both a portable `backupProfileId` (what the
/// operations *mean*) and an `implementationProfileId` (how they are
/// carried on a wire). We refuse anything we do not recognise rather than
/// attempting a best-effort mapping: the whole seat is built on the idea
/// that a snapshot's terms and semantics are checkable, and guessing at an
/// unknown profile discards exactly that.
///
/// Spec: `onym-system/backup/UI-Backup.md` §5.1–5.2 and
/// `onym-system/backup/UI-Backup-Object-HTTP.md` §1.
public enum BackupProfile {
    /// The portable semantics: sealed device archives, holder-keyed,
    /// restore by possession only.
    public static let portableProfileId = "onym:backup-profile:sealed-device-archive-v1"

    /// The wire mapping: HTTPS object operations, SHA-256 hex references,
    /// AES-256-GCM sealing, Ed25519 request-bound proof of possession.
    public static let implementationProfileId = "onym:backup-implementation:object-http-v1"

    /// Pinned suite identifiers, echoed by the operator's `/profile.json`.
    /// A mismatch on any of these means the operator is speaking a
    /// different protocol under the same name.
    public static let digestSuite = "sha-256/lowercase-hex"
    public static let sealingSuite = "aes-256-gcm/hkdf-sha256-from-bip39-seed"
    public static let incrementModel = "whole-snapshot-transfer-chunked-v1"
    public static let authentication = "holder-scoped-capability/ed25519-request-bound-v1"
    public static let paymentRefusal = "onym-payment-required-v1"

    /// The operations this profile requires an operator to implement.
    /// `connect` is client-side (manifest and terms verification), so it
    /// is not in the wire set.
    public static let requiredOperations: Set<String> = [
        "upload", "list", "download", "erase", "export",
    ]

    public static func supports(portableProfileId id: String) -> Bool {
        id == portableProfileId
    }

    public static func supports(implementationProfileId id: String) -> Bool {
        id == implementationProfileId
    }
}

/// An operator's `/profile.json`, checked against what we implement.
///
/// Kept as a plain decoded value with no behaviour beyond `review`: it is
/// untrusted input describing a counterparty's claims, and the only useful
/// question about it is whether we can proceed.
public struct BackupImplementationProfile: Sendable, Equatable {
    public let implementationVersion: Int
    public let implementationProfileId: String
    public let backupProfileId: String
    public let digestSuite: String
    public let sealingSuite: String
    public let incrementModel: String
    public let authentication: [String]
    public let paymentRefusal: String

    public init(
        implementationVersion: Int,
        implementationProfileId: String,
        backupProfileId: String,
        digestSuite: String,
        sealingSuite: String,
        incrementModel: String,
        authentication: [String],
        paymentRefusal: String
    ) {
        self.implementationVersion = implementationVersion
        self.implementationProfileId = implementationProfileId
        self.backupProfileId = backupProfileId
        self.digestSuite = digestSuite
        self.sealingSuite = sealingSuite
        self.incrementModel = incrementModel
        self.authentication = authentication
        self.paymentRefusal = paymentRefusal
    }

    /// Decode and check in one step. Every failure is
    /// `.unsupportedProfile`, because from the caller's side they are the
    /// same event: this operator cannot be used by this build, and the
    /// remedy is a client that implements the profile — not a retry.
    public static func review(raw: Data) throws -> BackupImplementationProfile {
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw BackupError.unsupportedProfile
        }
        guard
            let implementationVersion = object["implementationVersion"] as? Int,
            let implementationProfileId = object["implementationProfileId"] as? String,
            let backupProfileId = object["backupProfileId"] as? String,
            let digestSuite = object["digestSuite"] as? String,
            let sealingSuite = object["sealingSuite"] as? String,
            let incrementModel = object["incrementModel"] as? String,
            let paymentRefusal = object["paymentRefusal"] as? String
        else {
            throw BackupError.unsupportedProfile
        }
        let authentication = (object["authentication"] as? [String]) ?? []

        let profile = BackupImplementationProfile(
            implementationVersion: implementationVersion,
            implementationProfileId: implementationProfileId,
            backupProfileId: backupProfileId,
            digestSuite: digestSuite,
            sealingSuite: sealingSuite,
            incrementModel: incrementModel,
            authentication: authentication,
            paymentRefusal: paymentRefusal
        )
        guard profile.isSupported else { throw BackupError.unsupportedProfile }
        return profile
    }

    /// Every pinned value must match. A profile that agrees on the
    /// identifier but differs on, say, the sealing suite is the more
    /// dangerous case of the two — it would upload bytes the operator
    /// believes are shaped differently than they are.
    public var isSupported: Bool {
        implementationVersion == 1
            && BackupProfile.supports(implementationProfileId: implementationProfileId)
            && BackupProfile.supports(portableProfileId: backupProfileId)
            && digestSuite == BackupProfile.digestSuite
            && sealingSuite == BackupProfile.sealingSuite
            && incrementModel == BackupProfile.incrementModel
            && paymentRefusal == BackupProfile.paymentRefusal
            && authentication.contains(BackupProfile.authentication)
    }
}
