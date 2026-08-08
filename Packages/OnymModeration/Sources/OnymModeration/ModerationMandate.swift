import Foundation
import CryptoKit

/// The consent artifact (Moderation.md §5.3): signed by the user at
/// onboarding, countersigned by the interface, binding exactly one
/// identity–device pair to one authority under one manifest hash.
/// Immutable once signed — switching authorities means signing a
/// fresh mandate, never editing this one.
public struct ModerationMandate: Codable, Sendable, Equatable {
    public let mandateVersion: Int
    /// `onym:key:<user-identity>`.
    public let user: String
    /// `onym:component:<interface-id>` — this app.
    public let interface: String
    /// `onym:component:<authority-id>`.
    public let authority: String
    /// SHA-256 (lowercase hex) of the exact manifest bytes consented to.
    public let manifestHash: String
    public let classes: [String]
    /// Vendor-local opaque enrollment identifier issued by the
    /// enforcement backend — NOT a DeviceCheck token (tokens are
    /// ephemeral and unlinkable by design; profile §5).
    public let deviceBinding: String
    public let acceptedAt: Date
    /// `[userSignature, interfaceSignature]`, base64. The interface
    /// countersignature comes from the enforcement backend; a stub
    /// backend appends a sentinel that can never verify (see
    /// `StubEnforcementBackendClient`).
    public var signatures: [String]

    public init(
        mandateVersion: Int = 1,
        user: String,
        interface: String,
        authority: String,
        manifestHash: String,
        classes: [String],
        deviceBinding: String,
        acceptedAt: Date,
        signatures: [String] = []
    ) {
        self.mandateVersion = mandateVersion
        self.user = user
        self.interface = interface
        self.authority = authority
        self.manifestHash = manifestHash
        self.classes = classes
        self.deviceBinding = deviceBinding
        self.acceptedAt = acceptedAt
        self.signatures = signatures
    }

    /// The bytes the user (and later the interface) sign: every field
    /// except `signatures`, JSON-encoded with sorted keys and ISO 8601
    /// dates. Built from an explicit payload type — no `signatures`
    /// field at all, so countersigning can't change the signed content,
    /// and no string surgery on already-encoded JSON. `ModerationSigningPayloadTests`
    /// guards the mirror against field drift.
    ///
    /// PROVISIONAL: the draft spec defines no canonical JSON form.
    /// `.sortedKeys` + ISO 8601 is deterministic for this encoder but
    /// is not a cross-implementation canonical encoding — when the
    /// spec fixes one, only this helper changes, and mandates signed
    /// before then will need re-consent.
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let mandateVersion: Int
            let user, interface, authority, manifestHash: String
            let classes: [String]
            let deviceBinding: String
            let acceptedAt: Date
        }
        let unsigned = Unsigned(
            mandateVersion: mandateVersion,
            user: user,
            interface: interface,
            authority: authority,
            manifestHash: manifestHash,
            classes: classes,
            deviceBinding: deviceBinding,
            acceptedAt: acceptedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(unsigned)
    }

    /// `mandateRef` as verdicts and notices carry it: SHA-256
    /// (lowercase hex) over `signingBytes()`. Signature-independent so
    /// the reference is stable across countersigning. Same PROVISIONAL
    /// caveat as `signingBytes()`.
    public func mandateHash() throws -> String {
        let bytes = try signingBytes()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
