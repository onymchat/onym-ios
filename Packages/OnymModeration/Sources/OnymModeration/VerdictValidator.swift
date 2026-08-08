import Foundation
import os.log
import OnymFoundation

/// Pure, stateless verdict shape validation — the client's half of the
/// spec's "the interface executes verdicts mechanically" (Moderation.md
/// §5.7). Mark *writes* happen only in the enforcement backend; the
/// client validates every verdict it displays so a malformed sanction
/// is never rendered as legitimate.
///
/// Checks are exactly the §5.6 normative constraints; the validator
/// never weighs the verdict's wisdom.
public struct VerdictValidator: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The verdict's marks state is executable now.
        case execute
        /// A valid ban whose `executeAfter` hasn't arrived: stored,
        /// not executed — writing its mark early is nonconforming.
        case storeUntilExecuteAfter(Date)
    }

    private static let log = Logger(subsystem: "app.onym.ios", category: "ModerationVerdict")

    public init() {}

    /// Validate `verdict` against the mandate it references and the
    /// manifest that mandate consented to.
    ///
    /// - Parameters:
    ///   - consented: must be the very manifest `mandate.manifestHash`
    ///     pins — validating against any other manifest would validate
    ///     against terms the user never consented to.
    ///   - enforceSignature: signature failures throw only under
    ///     enforcement (soft mode logs and continues — no real authority
    ///     signs verdicts yet; see `ModerationTrust`).
    /// - Returns: whether the verdict is executable now or stored until
    ///   its `executeAfter`.
    /// - Throws: `ModerationError` on any shape violation.
    public func validate(
        _ verdict: Verdict,
        mandate: ModerationMandate,
        consented: SignedManifest,
        now: Date,
        enforceSignature: Bool = ModerationTrust.enforceVerdictSignatures
    ) throws -> Outcome {
        // The manifest handed in must be the mandate's pinned manifest,
        // not merely *a* manifest from this authority.
        guard consented.manifestHash == mandate.manifestHash else {
            throw ModerationError.verdictInvalid("consented manifest is not the mandate's pinned manifest")
        }

        // Authority signature (spec §5.7: "authority signature" is the
        // first mechanical check), keyed on the consented manifest's
        // operator key through the one `AuthorityKey` parser. An
        // unparseable key yields a nil-key verifier, which never
        // validates — the soft/enforce policy then applies.
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: try? consented.manifest.operatorPublicKey())
        try validateSignature(verdict, verifier: verifier, enforce: enforceSignature)

        // Mandate reference: the verdict must name a mandate this user
        // actually signed, for this authority, on this device.
        guard verdict.authority == mandate.authority else {
            throw ModerationError.verdictInvalid("authority \(verdict.authority) is not the mandated authority")
        }
        guard let mandateHash = try? mandate.mandateHash(), verdict.mandateRef == mandateHash else {
            throw ModerationError.noMandate
        }
        guard verdict.accusedKeys.contains(mandate.user) else {
            throw ModerationError.verdictInvalid("the mandate's user is not among accusedKeys")
        }
        guard verdict.deviceBinding == mandate.deviceBinding else {
            throw ModerationError.verdictInvalid("deviceBinding outside the mandate")
        }

        // Class within mandate, and within the consented manifest.
        guard mandate.classes.contains(verdict.classId) else {
            throw ModerationError.classOutsideMandate(verdict.classId)
        }
        guard let violationClass = consented.manifest.violationClass(id: verdict.classId) else {
            throw ModerationError.verdictInvalid("class \(verdict.classId) missing from consented manifest")
        }

        // Reasoning is mandatory on every disposition — an unexplained
        // sanction (or case opening) is nonconforming.
        guard !verdict.reasoning.isEmpty else {
            throw ModerationError.verdictInvalid("missing reasoning")
        }

        switch verdict.disposition {
        case .openCase:
            return try validateOpenCase(verdict)
        case .dismiss:
            return try validateDismissal(verdict)
        case .ban:
            return try validateBan(verdict, violationClass: violationClass, now: now)
        }
    }

    // MARK: - Per-disposition shape

    /// §5.6 constraint 7: the interim object's only permitted effect is
    /// the case-open mark; it carries no sanction fields and is never
    /// final.
    private func validateOpenCase(_ verdict: Verdict) throws -> Outcome {
        guard verdict.marks == Marks(caseOpen: true, banned: false) else {
            throw ModerationError.verdictInvalid("open-case marks inconsistent with disposition")
        }
        guard verdict.banExpires == nil, verdict.executeAfter == nil,
              verdict.appealDeadline == nil, !verdict.isFinal
        else {
            throw ModerationError.verdictInvalid("open-case verdict carries sanction fields")
        }
        return .execute
    }

    /// Dismissals clear both marks (§5.6 constraint 6).
    private func validateDismissal(_ verdict: Verdict) throws -> Outcome {
        guard verdict.marks == Marks(caseOpen: false, banned: false) else {
            throw ModerationError.verdictInvalid("dismissal marks inconsistent with disposition")
        }
        return .execute
    }

    /// §5.6 constraints 3–4: expiry present unless the consented term
    /// is permanent; `executeAfter` present and consistent with the
    /// class's appeal effect; early execution refused.
    private func validateBan(
        _ verdict: Verdict,
        violationClass: ViolationClass,
        now: Date
    ) throws -> Outcome {
        guard verdict.marks == Marks(caseOpen: false, banned: true) else {
            throw ModerationError.verdictInvalid("ban marks inconsistent with disposition")
        }
        if violationClass.banTerm != .permanent, verdict.banExpires == nil {
            throw ModerationError.verdictInvalid("ban missing banExpires on non-permanent class")
        }
        guard let executeAfter = verdict.executeAfter else {
            throw ModerationError.verdictInvalid("ban missing executeAfter")
        }
        switch violationClass.appealEffect {
        case .nonSuspensive:
            guard executeAfter == verdict.decidedAt else {
                throw ModerationError.verdictInvalid("non-suspensive executeAfter must equal decidedAt")
            }
        case .suspensive:
            guard let appealDeadline = verdict.appealDeadline, executeAfter == appealDeadline else {
                throw ModerationError.verdictInvalid("suspensive executeAfter must equal appealDeadline")
            }
        }
        if executeAfter > now {
            return .storeUntilExecuteAfter(executeAfter)
        }
        return .execute
    }

    // MARK: - Signature

    private func validateSignature(
        _ verdict: Verdict,
        verifier: Ed25519DetachedSignatureVerifier,
        enforce: Bool
    ) throws {
        guard
            let signature = Data(base64Encoded: verdict.signature),
            let bytes = try? verdict.signingBytes(),
            verifier.isValid(signature: signature, for: bytes)
        else {
            if enforce {
                Self.log.error("verdict \(verdict.caseId, privacy: .public): signature did NOT verify; rejecting (enforcement ON)")
                throw ModerationError.verdictInvalid("authority signature did not verify")
            }
            Self.log.warning("verdict \(verdict.caseId, privacy: .public): signature did NOT verify; accepting anyway (enforcement OFF)")
            return
        }
    }
}
