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
    /// An accused-side case operation was attempted without standing:
    /// the case's mandate is retained but the active identity does not
    /// own it. Standing follows the mandate a case was opened under,
    /// so switching the selected identity — not switching authorities —
    /// is what resolves this.
    case caseAccessUnavailable(String)
    /// The enforcement backend's countersignature failed the local
    /// plausibility check (not a 64-byte Ed25519 signature). The
    /// consent attempt is aborted rather than recorded as countersigned.
    case countersignatureInvalid(String)
    /// A case statement failed local validation (empty, or beyond the
    /// reference Authority's byte cap) before any signing or delivery.
    case statementInvalid(String)
    /// Internal ledger invariant violation (a record whose payload
    /// doesn't match its kind). Unreachable by construction from any
    /// user input; surfaced distinctly so it is never rendered as a
    /// validation message.
    case ledgerInconsistent(String)
    /// The Authority answered 409: it already holds this exact report.
    /// A terminal, benign outcome — the allegation is on file — but the
    /// original receipt (caseId) cannot be recovered without a lookup
    /// endpoint the Authority protocol doesn't define yet.
    case reportAlreadyFiled(reportId: String)
    /// DeviceCheck is unsupported here (simulator, enterprise-signed
    /// build). Callers degrade toward gate-check-required, never toward
    /// unmoderated operation (profile §8.5).
    case attestationUnavailable
    /// A recovery grant that does not parse, or a recovery answer in
    /// a shape this client does not speak.
    case grantInvalid(String)
    /// The operation exists in the protocol surface but the concrete
    /// implementation is a stub (no enforcement backend / authority
    /// service is deployed yet).
    case notImplemented(String)
}
