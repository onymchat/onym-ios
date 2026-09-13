import Foundation
import OnymIdentity
import OnymStellar
import OnymFoundation

/// What happened when someone tried to act on a proposal.
public enum TreasuryActionOutcome: Equatable, Sendable {
    case signed
    /// This identity's declared signer is external, so the app cannot
    /// sign. Carries the SEP-0007 request to hand to their wallet.
    case needsExternalWallet(SEP0007Request)
    /// Applied. Carries the transaction hash.
    case submitted(txHash: String)
    /// Not enough weight yet — how much there is, and how much is
    /// needed.
    case notEnoughWeight(weight: UInt32, required: UInt32)
    /// Another transaction consumed this one's sequence number. The
    /// only way forward is a fresh proposal.
    case superseded
    case expired
    /// This identity has not declared a signer, or is not one.
    case notASigner
    case failed(String)
}

/// Signing and submitting proposals.
///
/// A stateless coordinator over the repository, the identity seam and
/// Horizon — the "one-shot workflow" shape the architecture reserves
/// for operations that span several dependencies without owning
/// durable state.
public struct TreasurySigningInteractor: Sendable {
    private let treasury: TreasuryRepository
    private let identity: IdentityRepository
    private let broadcaster: TreasuryBroadcaster
    private let horizon: @Sendable (StellarNetwork) -> any HorizonClient

    public init(
        treasury: TreasuryRepository,
        identity: IdentityRepository,
        broadcaster: TreasuryBroadcaster,
        horizon: @escaping @Sendable (StellarNetwork) -> any HorizonClient = { network in
            URLSessionHorizonClient(network: network)
        }
    ) {
        self.treasury = treasury
        self.identity = identity
        self.broadcaster = broadcaster
        self.horizon = horizon
    }

    /// Sign a proposal as the current identity.
    ///
    /// Takes one of two paths depending on what this identity declared.
    /// For an Onym-derived signer the app holds the key and signs here.
    /// For an external one it cannot, and returns the SEP-0007 request
    /// for the caller to open — the private key never comes near this
    /// app, which is the entire point of supporting external accounts.
    public func sign(proposalID: UUID, now: Date = Date()) async -> TreasuryActionOutcome {
        guard let stored = await treasury.proposal(id: proposalID) else {
            return .failed("proposal not found")
        }
        let proposal = stored.proposal
        if let rejection = stored.rejection {
            return .failed("refused: \(rejection.rawValue)")
        }
        if let expiresAt = proposal.expiresAt, expiresAt <= now {
            return .expired
        }

        let snapshot = await treasury.snapshot(groupID: proposal.groupID)
        guard let me = await identity.currentIdentity(),
              let mine = snapshot.declarations.first(where: {
                  $0.memberBlsPubkeyHex == me.blsPublicKey.hexString
              })
        else { return .notASigner }

        switch mine.source {
        case .external:
            return .needsExternalWallet(SEP0007Request(
                envelope: proposal.envelope,
                network: proposal.network,
                message: message(for: proposal),
                publicKey: mine.account
            ))

        case .onym:
            // The hash is computed here from the envelope this device
            // decoded — never supplied by a caller. `signWithTreasuryKey`
            // is documented to take a transaction hash and nothing else,
            // and this is the only place that calls it.
            let hash = proposal.envelope.transaction.hash(network: proposal.network)
            guard let signature = try? await identity.signWithTreasuryKey(hash) else {
                return .failed("could not sign")
            }
            guard await treasury.addSignature(
                signature,
                from: mine.account,
                toProposal: proposalID,
                now: now
            ) else {
                return .failed("signature did not verify")
            }
            await broadcaster.broadcastSignature(
                proposal: proposal,
                signature: signature,
                signer: mine.account,
                now: now
            )
            return .signed
        }
    }

    /// Take the signatures out of an envelope a wallet returned.
    ///
    /// The returned transaction is discarded — see
    /// `TransactionEnvelope.harvestSignatures`. Only signatures that
    /// verify against this device's own hash, and that belong to a
    /// declared signer, are kept; each one is then broadcast so the
    /// rest of the group's devices can count it too.
    public func adoptSignatures(
        fromReturned returned: TransactionEnvelope,
        proposalID: UUID,
        now: Date = Date()
    ) async -> TreasuryActionOutcome {
        guard let stored = await treasury.proposal(id: proposalID) else {
            return .failed("proposal not found")
        }
        let proposal = stored.proposal
        let snapshot = await treasury.snapshot(groupID: proposal.groupID)
        let candidates = snapshot.declarations.map(\.account)

        var working = proposal.envelope
        let adopted = working.harvestSignatures(
            from: returned,
            candidates: candidates,
            network: proposal.network
        )
        guard !adopted.isEmpty else {
            return .failed("that transaction carried no signature we could use")
        }

        for signer in adopted {
            guard let decorated = working.signatures.first(where: {
                $0.hint == signer.signatureHint
            }) else { continue }
            await treasury.addSignature(
                decorated.signature,
                from: signer,
                toProposal: proposalID,
                now: now
            )
            await broadcaster.broadcastSignature(
                proposal: proposal,
                signature: decorated.signature,
                signer: signer,
                now: now
            )
        }
        return .signed
    }

    /// Submit a proposal that has reached its threshold.
    ///
    /// Re-reads the account first, always. The signer set and the
    /// thresholds are exactly what a control proposal changes, so
    /// deciding "ready" from a cached snapshot would risk submitting
    /// against a quorum that no longer exists — and a rejected
    /// submission is a wasted fee and a consumed sequence number.
    public func submit(proposalID: UUID, now: Date = Date()) async -> TreasuryActionOutcome {
        guard let stored = await treasury.proposal(id: proposalID) else {
            return .failed("proposal not found")
        }
        let proposal = stored.proposal
        guard let account = await treasury.refresh(groupID: proposal.groupID) else {
            return .failed("could not read the treasury account")
        }
        let snapshot = await treasury.snapshot(groupID: proposal.groupID)

        switch TreasuryProposalVerifier.standing(
            of: proposal,
            account: account,
            declaredSigners: snapshot.declarations.map(\.account),
            now: now
        ) {
        case .ready:
            break
        case .collecting(let weight, let required):
            return .notEnoughWeight(weight: weight, required: required)
        case .superseded:
            return .superseded
        case .expired:
            return .expired
        case .submitted(let hash):
            return .submitted(txHash: hash)
        case .rejected(let reason):
            return .failed("refused: \(reason.rawValue)")
        }

        do {
            let hash = try await horizon(proposal.network).submit(proposal.envelope)
            await treasury.markSubmitted(proposalID: proposalID, txHash: hash)
            return .submitted(txHash: hash)
        } catch let error as HorizonError {
            // `tx_bad_seq` means somebody else's transaction won the
            // race between the refresh above and this submit. Reported
            // as superseded rather than as a generic failure, because
            // the two need different things from the user: one is "try
            // again", the other is "this can never work, propose
            // again".
            if case .submissionFailed(let codes, _) = error,
               codes.contains("tx_bad_seq") {
                return .superseded
            }
            return .failed(describe(error))
        } catch {
            return .failed("submission failed")
        }
    }

    /// What the wallet shows the signer. Short, and built from the
    /// **decoded** operations rather than from anything a proposer
    /// wrote — the same rule the in-app card follows.
    private func message(for proposal: TreasuryProposal) -> String {
        switch proposal.kind {
        case .payment:
            if case .payment(let destination, let asset, let amount)
                = proposal.operations.first?.body {
                return "Pay \(amount.decimalString) \(asset.code) to \(destination.abbreviated)"
            }
            return "Treasury payment"
        case .trustline:
            if case .changeTrust(let asset, _) = proposal.operations.first?.body {
                return "Trust \(asset.code)"
            }
            return "Treasury trustline"
        case .addSigner:
            return "Add a treasury co-signer"
        case .changeControl:
            return "Change treasury control"
        }
    }

    private func describe(_ error: HorizonError) -> String {
        switch error {
        case .submissionFailed(let codes, _):
            return codes.isEmpty
                ? "the network rejected it"
                : "the network rejected it (\(codes.joined(separator: ", ")))"
        case .accountNotFound:
            return "the treasury account does not exist yet"
        case .invalidResponse, .decodeFailure:
            return "could not reach the network"
        }
    }
}
