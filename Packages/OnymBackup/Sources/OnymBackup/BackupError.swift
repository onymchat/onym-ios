import Foundation

/// The error vocabulary of `UI-Backup.md` §13, mapped in
/// `UI-Backup-Object-HTTP.md` §14.
///
/// Two rules shape this enum:
///
/// - **An unknown operator code is preserved, not flattened.** `.rejected`
///   carries the operator's own code and message so a person sees what the
///   counterparty actually said rather than our guess at it
///   (`UI-Backup.md` §8.9).
/// - **`exportWithheld` exists so a client can name a violation.** It is
///   not a state an operator may put us in: export is unconditional
///   (§14.15). A client that receives it records the operator's
///   non-conformance and must not soften the wording it shows.
public enum BackupError: Error, Equatable, Sendable {
    /// The operator's profile is not one this build implements.
    case unsupportedProfile
    /// Endpoint syntax, scheme, or origin is unusable. Never rewritten
    /// silently into something that works.
    case invalidEndpoint
    /// Reference syntax, algorithm, or byte count is malformed.
    case invalidReference
    /// Terms could not be fetched or verified. Enrolment cannot proceed:
    /// terms are a precondition, not a nicety.
    case termsUnavailable
    /// The operator's current terms differ from the ones we pinned. Stop,
    /// re-present, obtain fresh consent.
    case termsChanged(currentTermsId: String?)
    /// Terms on offer are weaker than those a retained snapshot pinned.
    /// Refused outright — terms bind forward only (`UI-Backup.md` §10.2).
    case termsRegression(field: String)
    /// Proof of possession was refused: bad signature, stale timestamp, or
    /// a replayed nonce.
    case accessRefused
    /// The operator requires a valid entitlement for this operation.
    case paymentRequired(componentId: String, offerIds: [String], entitlementIssuers: [String])
    /// An entitlement was presented and refused. Refresh without leaking
    /// another credential to this operator.
    case invalidEntitlement
    /// Exceeds the operator's declared maximum sealed snapshot size.
    case snapshotTooLarge(maximumSealedSnapshotBytes: Int?)
    /// Retained count or byte limit reached. The operator reports it and
    /// must not silently drop an older snapshot to make room.
    case quotaExceeded(retainedSnapshots: Int?, maximumRetainedSnapshots: Int?)
    /// Bytes received do not compose the reference claimed. Never merged,
    /// never partially restored.
    case incompleteSnapshot
    /// Held once; no longer held.
    case retentionExpired
    /// Erasure acknowledged, completion pending. Not destruction.
    ///
    /// Never an operator response: erase always returns a receipt, and a
    /// receipt is always an acknowledgment. This is *derived* locally by
    /// comparing the receipt's `completionCommittedBy` against the clock,
    /// so an operator that misses its own committed deadline is caught
    /// from the receipt we already hold rather than from a status code it
    /// would have to volunteer against its own interest.
    case erasureUnconfirmed(receipt: ErasureReceipt?)
    /// The operator withheld export. **Non-conforming** — see the note above.
    case exportWithheld
    /// Nothing was decided. Distinct from a refusal, and from `unknown`.
    case operatorUnavailable
    /// The operator refused with a code we do not model. Preserved verbatim.
    case rejected(code: String, message: String?)
    /// A local precondition failed before anything left the device.
    case localFailure(reason: LocalFailureReason)

    public enum LocalFailureReason: String, Sendable, Equatable {
        /// This identity has no recovery phrase (imported from raw key
        /// material), so no restorable archive can be sealed for it.
        case noRecoveryPhrase
        /// The sealed bytes we were asked to upload are gone from the
        /// pending directory.
        case sealedBytesUnavailable
        /// The archive did not decode, or its schema is from a newer
        /// client.
        case archiveUnreadable
        /// The composed archive would contain material the eligible set
        /// forbids. Should be unreachable by construction; if it ever
        /// fires, it is a bug worth failing loudly for.
        case ineligibleContent
    }
}

extension BackupError {
    /// The wire code this error corresponds to, for logging and for
    /// mapping an operator response back onto the enum.
    public var code: String {
        switch self {
        case .unsupportedProfile: "unsupported_profile"
        case .invalidEndpoint: "invalid_endpoint"
        case .invalidReference: "invalid_reference"
        case .termsUnavailable: "terms_unavailable"
        case .termsChanged: "terms_changed"
        case .termsRegression: "terms_regression"
        case .accessRefused: "signature_invalid"
        case .paymentRequired: "payment_required"
        case .invalidEntitlement: "invalid_entitlement"
        case .snapshotTooLarge: "snapshot_too_large"
        case .quotaExceeded: "quota_exceeded"
        case .incompleteSnapshot: "digest_mismatch"
        case .retentionExpired: "retention_expired"
        case .erasureUnconfirmed: "erasure_unconfirmed"
        case .exportWithheld: "export_withheld"
        case .operatorUnavailable: "operator_unavailable"
        case .rejected(let code, _): code
        case .localFailure(let reason): "local_\(reason.rawValue)"
        }
    }

    /// True when retrying the *same* operation, unchanged, could succeed.
    ///
    /// `paymentRequired` is retriable because that is exactly the shape of
    /// the payment loop: refuse, purchase, retry the same bytes under the
    /// same operation id (`UI-Backup-Object-HTTP.md` §10.2). `termsChanged`
    /// is not, because a retry would upload under terms nobody consented
    /// to.
    public var isRetriable: Bool {
        switch self {
        case .operatorUnavailable, .paymentRequired, .accessRefused:
            true
        default:
            false
        }
    }
}
