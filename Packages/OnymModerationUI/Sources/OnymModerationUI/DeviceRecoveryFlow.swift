import Foundation
import Observation
import OnymModeration

/// The device-recovery conversation, as the blocked holder sees it:
/// file a claim (a real contact, and their account of how they hold
/// the marked device), wait for a human at the authority to decide,
/// then redeem the signed grant at the enforcement backend. There is
/// no self-serve step anywhere in this flow — every transition that
/// could unblock the device passes through the moderator's decision.
@MainActor
@Observable
public final class DeviceRecoveryFlow: Identifiable {
    public enum Phase: Equatable {
        /// No claim on file: show the form.
        case form
        case filing
        /// Filed; a human decides. Poll with the check button / on
        /// appearance.
        case awaitingReview(claimId: String)
        case checking(claimId: String)
        /// The moderator refused, with reasons. `startOver()` files a
        /// fresh claim (e.g. with a reachable contact this time).
        case refused(reasons: String)
        case redeeming
        /// The grant was issued but a record still bans the device —
        /// the case's, or this identity's own. The grant is kept; the
        /// routes point back at the authority.
        case markInForce(authorityContact: String, newHolderURL: URL?, appealURL: URL?)
        /// Redeemed and reconciled. The gate publishes the new status
        /// itself, so this phase is normally visible only for the
        /// moment before the blocking screen goes away.
        case recovered
    }

    public private(set) var phase: Phase
    /// A transient problem (network, refusal) that leaves the phase
    /// actionable; rendered under the current phase's controls.
    public private(set) var errorMessage: String?

    private let claimStore: any RecoveryClaimStore
    /// The identity key claims are filed and polled under. A persisted
    /// claim belongs to the key that signed it — the authority answers
    /// it to no other — so a claim from a previous identity must not
    /// resume here.
    private let grantee: String
    private let fileClaim: @MainActor (_ contact: String, _ statement: String) async throws -> String
    private let claimStatus: @MainActor (_ claimId: String) async throws -> RecoveryClaimStatus
    private let redeem: @MainActor (RecoveryGrant) async -> RecoveryRedemption

    public init(
        claimStore: any RecoveryClaimStore,
        grantee: String,
        fileClaim: @escaping @MainActor (_ contact: String, _ statement: String) async throws -> String,
        claimStatus: @escaping @MainActor (_ claimId: String) async throws -> RecoveryClaimStatus,
        redeem: @escaping @MainActor (RecoveryGrant) async -> RecoveryRedemption
    ) {
        self.claimStore = claimStore
        self.grantee = grantee
        self.fileClaim = fileClaim
        self.claimStatus = claimStatus
        self.redeem = redeem
        if let claimId = claimStore.load(grantee: grantee) {
            phase = .awaitingReview(claimId: claimId)
        } else {
            phase = .form
        }
    }

    // MARK: - Intents

    public func submitClaim(contact: String, statement: String) async {
        guard case .form = phase else { return }
        let contact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.isEmpty, !statement.isEmpty else {
            errorMessage = String(localized: "Both a contact and your account of the device are required — a person reads this claim and needs a way to reach you.")
            return
        }
        phase = .filing
        errorMessage = nil
        do {
            let claimId = try await fileClaim(contact, statement)
            claimStore.save(claimId, grantee: grantee)
            phase = .awaitingReview(claimId: claimId)
        } catch {
            phase = .form
            errorMessage = Self.describe(error)
        }
    }

    /// Poll the claim; when a grant is on it, redeem immediately —
    /// the person already asked by filing, and the moderator already
    /// decided by granting.
    public func checkClaim() async {
        guard let claimId = pollableClaimId else { return }
        phase = .checking(claimId: claimId)
        errorMessage = nil
        do {
            let status = try await claimStatus(claimId)
            switch status.state {
            case "granted":
                guard let grant = status.grant else {
                    phase = .awaitingReview(claimId: claimId)
                    errorMessage = String(localized: "The claim is granted but the grant hasn't arrived yet. Try again in a moment.")
                    return
                }
                await redeemGrant(grant, claimId: claimId)
            case "refused":
                claimStore.save(nil, grantee: grantee)
                phase = .refused(
                    reasons: status.reasoning
                        ?? String(localized: "The moderator did not include reasons.")
                )
            default:
                phase = .awaitingReview(claimId: claimId)
            }
        } catch {
            phase = .awaitingReview(claimId: claimId)
            errorMessage = Self.describe(error)
        }
    }

    /// After a refusal, a claim the authority no longer knows, or to
    /// correct a bad contact: drop the old claim and show the form
    /// again.
    public func startOver() {
        claimStore.save(nil, grantee: grantee)
        errorMessage = nil
        phase = .form
    }

    // MARK: - Private

    /// `.checking` is deliberately NOT pollable: it means a check is
    /// already in flight, and a second one racing it could redeem the
    /// same single-use grant twice — the loser's failure would then
    /// overwrite the winner's success. `.markInForce` IS pollable (the
    /// claim and its grant were kept): "check again" after resolving
    /// things with the authority re-polls and re-redeems.
    private var pollableClaimId: String? {
        switch phase {
        case .awaitingReview(let claimId):
            return claimId
        case .markInForce:
            return claimStore.load(grantee: grantee)
        default:
            return nil
        }
    }

    private func redeemGrant(_ grant: RecoveryGrant, claimId: String) async {
        phase = .redeeming
        switch await redeem(grant) {
        case .recovered:
            // The claim served its purpose; the gate repository has
            // already published the new status.
            claimStore.save(nil, grantee: grantee)
            phase = .recovered
        case .markInForce(let contact, let newHolderURL, let appealURL):
            // Keep the claim: the grant on it stays valid for after
            // the authority resolves whatever still stands.
            phase = .markInForce(
                authorityContact: contact,
                newHolderURL: newHolderURL,
                appealURL: appealURL
            )
        case .failed(let message):
            phase = .awaitingReview(claimId: claimId)
            errorMessage = message
        }
    }

    private static func describe(_ error: Error) -> String {
        if case let AuthorityClientError.rejected(rejection) = error {
            return rejection.message
        }
        if let error = error as? ModerationError, case .noMandate = error {
            return String(localized: "No moderation authority is configured for this identity yet. Complete the consent step, then file the claim.")
        }
        return String(localized: "The authority could not be reached. Check the connection and try again.")
    }
}
