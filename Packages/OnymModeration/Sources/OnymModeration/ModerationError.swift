import Foundation

/// Client-relevant subset of the moderation spec's error table
/// (Moderation.md §10), plus the client-only conditions the DeviceCheck
/// profile introduces (attestation availability, unimplemented stub
/// operations).
public enum ModerationError: Error, Sendable, Equatable {
    /// The authority's manifest declares a profile this client doesn't
    /// implement, or a duration/term outside the supported grammar.
    case unsupportedProfile(String)
    /// A manifest window/term used a duration string outside the
    /// `P<n>D` subset this client parses.
    case invalidDuration(String)
    /// A verdict referenced no mandate this user signed.
    case noMandate
    /// A verdict named a violation class outside the consented mandate.
    case classOutsideMandate(String)
    /// A verdict failed mechanical shape validation (Moderation.md
    /// §5.6). The reason is developer-facing diagnostic detail.
    case verdictInvalid(String)
    /// The manifest failed decode, signature, or consent-time validity
    /// validation (`AuthorityManifestValidator`).
    case manifestInvalid(String)
    /// A key reference (`onym:key:<hex>`, or a directory listing's
    /// base64 operator key) could not be parsed as an Ed25519 public
    /// key. See `AuthorityKey`.
    case keyInvalid(String)
    /// A component reference (`onym:component:<identifier>`) could not
    /// be parsed — absent prefix, or an empty/blank identifier naming
    /// no component. See `ComponentReference`.
    case componentReferenceInvalid(String)
    /// A persisted registration cannot be retried because its Authority
    /// is not present in the Interface's current designated directory.
    case authorityUnavailable(String)
    /// The requested artifact has already resolved (or was never a
    /// persisted registration attempt).
    case registrationNotPending
    /// Reporting requires a currently registered Authority mandate and
    /// a directory entry capable of receiving the signed report.
    case reportingUnavailable(String)
    /// The supplied evidence proof does not verify against the accused
    /// key over the exact content the user is about to disclose.
    case authenticityUnverified
    /// DeviceCheck is unsupported here (simulator, enterprise-signed
    /// build). Callers degrade toward gate-check-required, never toward
    /// unmoderated operation (profile §8.5).
    case attestationUnavailable
    /// The operation exists in the protocol surface but the concrete
    /// implementation is a stub (no enforcement backend / authority
    /// service is deployed yet).
    case notImplemented(String)
}
