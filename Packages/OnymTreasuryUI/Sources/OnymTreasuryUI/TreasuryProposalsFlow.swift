import Foundation
import Observation
import OnymFoundation
import OnymIdentity
import OnymStellar
import OnymTreasury

/// A member who could be proposed as a co-signer.
public struct TreasuryNominee: Identifiable, Equatable, Sendable {
    public let alias: String
    public let account: StellarAccountID
    public let isUnprovenExternal: Bool

    public var id: String { account.accountID }

    public init(alias: String, account: StellarAccountID, isUnprovenExternal: Bool) {
        self.alias = alias
        self.account = account
        self.isUnprovenExternal = isUnprovenExternal
    }
}

/// One proposal, decoded and ready to draw.
public struct TreasuryProposalRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let description: TreasuryProposalDescription
    public let standing: TreasuryProposalStanding?
    public let proposerAlias: String
    public let createdAt: Date
    public let expiresAt: Date?
    /// Declared signers who have signed, by alias — "waiting on Bo" is
    /// more use than "2 of 3".
    public let signedBy: [String]
    public let waitingOn: [String]
    /// Whether the current identity can add a signature right now.
    public let canSign: Bool
    public let canSubmit: Bool

    public init(
        id: UUID,
        description: TreasuryProposalDescription,
        standing: TreasuryProposalStanding?,
        proposerAlias: String,
        createdAt: Date,
        expiresAt: Date?,
        signedBy: [String],
        waitingOn: [String],
        canSign: Bool,
        canSubmit: Bool
    ) {
        self.id = id
        self.description = description
        self.standing = standing
        self.proposerAlias = proposerAlias
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.signedBy = signedBy
        self.waitingOn = waitingOn
        self.canSign = canSign
        self.canSubmit = canSubmit
    }
}

/// Proposals for one group: listing them, acting on them, and making
/// new ones.
///
/// Separate from `TreasuryFlow` because the two answer different
/// questions and have different lifetimes — setup is a thing a group
/// does once, and this is the screen people come back to. They observe
/// the same repository stream.
@Observable
@MainActor
public final class TreasuryProposalsFlow {
    public let groupID: String

    // MARK: - Observed

    public private(set) var treasury: Treasury?
    public private(set) var rows: [TreasuryProposalRow] = []
    public private(set) var balances: [HorizonBalance] = []
    public private(set) var signers: [StellarSigner] = []
    public private(set) var thresholds: HorizonThresholds?
    public private(set) var history: [HorizonTransaction] = []
    public private(set) var isLoadingHistory = false
    /// Nil until a live account read has succeeded. The screen draws
    /// "checking…" rather than deciding anything from a cached signer
    /// set — see `TreasurySnapshot.standing(of:now:)`.
    public private(set) var hasLiveAccount = false
    /// Members who have declared an account that the treasury does not
    /// yet recognise as a signer — the people there is any point
    /// nominating.
    ///
    /// Derived from the **live** signer list, so someone already added
    /// stops appearing the moment the chain says so, rather than when
    /// this device next happens to notice.
    public private(set) var nominees: [TreasuryNominee] = []

    // MARK: - Transient

    public private(set) var actionError: String?
    public private(set) var busyProposalID: UUID?
    /// Set when signing needs the member's own wallet. The view opens
    /// it and clears this.
    public private(set) var walletRequest: SEP0007Request?
    /// Shown after a handoff: where the signed transaction comes back.
    public var pastedXDR = ""
    public var pasteTargetID: UUID?

    // MARK: - Compose

    public var paymentDestination = ""
    public var paymentAmount = ""
    public var paymentAssetCode = ""
    public var paymentAssetIssuer = ""
    public var trustlineCode = ""
    public var trustlineIssuer = ""
    public private(set) var composeError: String?
    public private(set) var isComposing = false

    public var paymentDestinationIsValid: Bool {
        StellarStrKey.isValidAccountID(normalized(paymentDestination))
    }

    /// Assets the treasury can actually pay in: the native lumen plus
    /// whatever it holds a trustline for. Offering a free-text asset
    /// field would let someone propose a payment in a token the
    /// treasury cannot send, which fails only at submit — after the
    /// group has signed it.
    public var payableAssets: [StellarAsset] {
        balances.map(\.asset)
    }

    // MARK: - Collaborators

    private let repository: TreasuryRepository
    private let identity: IdentityRepository
    private let signing: TreasurySigningInteractor
    private let proposing: TreasuryProposalInteractor
    private let aliases: @Sendable (String) async -> String
    private var started = false
    private var declarations: [TreasurySignerDeclarationRecord] = []
    private var myBlsHex: String?

    public init(
        groupID: String,
        repository: TreasuryRepository,
        identity: IdentityRepository,
        signing: TreasurySigningInteractor,
        proposing: TreasuryProposalInteractor,
        aliases: @escaping @Sendable (String) async -> String
    ) {
        self.groupID = groupID
        self.repository = repository
        self.identity = identity
        self.signing = signing
        self.proposing = proposing
        self.aliases = aliases
    }

    public func start() async {
        guard !started else { return }
        started = true
        myBlsHex = await identity.currentIdentity()?.blsPublicKey.hexStringValue
        // A live read before the first draw, so the screen does not sit
        // on "checking…" while a perfectly reachable network answers.
        await repository.refresh(groupID: groupID)
        for await snapshot in repository.snapshots(groupID: groupID) {
            await apply(snapshot)
        }
    }

    public func refresh() async {
        await repository.refresh(groupID: groupID)
    }

    public func loadHistory() async {
        guard treasury != nil else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        history = await repository.history(groupID: groupID)
    }

    private func apply(_ snapshot: TreasurySnapshot) async {
        treasury = snapshot.treasury
        declarations = snapshot.declarations
        hasLiveAccount = snapshot.account != nil
        balances = snapshot.account?.balances ?? []
        signers = snapshot.account?.signers ?? snapshot.treasury?.lastKnownSigners ?? []
        thresholds = snapshot.account?.thresholds ?? snapshot.treasury?.lastKnownThresholds

        let signerAccounts = Set(
            signers.filter { $0.weight > 0 }.map(\.key.accountID)
        )
        var candidates: [TreasuryNominee] = []
        for record in declarations where !signerAccounts.contains(record.account.accountID) {
            candidates.append(TreasuryNominee(
                alias: await aliases(record.memberBlsPubkeyHex),
                account: record.account,
                isUnprovenExternal: record.source == .external && record.provenAt == nil
            ))
        }
        nominees = candidates

        let now = Date()
        var built: [TreasuryProposalRow] = []
        for stored in snapshot.proposals {
            let proposal = stored.proposal
            let standing = snapshot.standing(of: stored, now: now)
            let signed = proposal.signers(among: declarations.map(\.account))
            let signedSet = Set(signed.map(\.accountID))

            var signedAliases: [String] = []
            var waitingAliases: [String] = []
            for record in declarations {
                let alias = await aliases(record.memberBlsPubkeyHex)
                if signedSet.contains(record.account.accountID) {
                    signedAliases.append(alias)
                } else {
                    waitingAliases.append(alias)
                }
            }

            let mine = declarations.first { $0.memberBlsPubkeyHex == myBlsHex }
            let alreadySigned = mine.map { signedSet.contains($0.account.accountID) } ?? false
            built.append(TreasuryProposalRow(
                id: proposal.id,
                description: TreasuryProposalDescription(proposal),
                standing: standing,
                proposerAlias: await aliases(proposal.proposerBlsPubkeyHex),
                createdAt: proposal.createdAt,
                expiresAt: proposal.expiresAt,
                signedBy: signedAliases,
                waitingOn: waitingAliases,
                canSign: mine != nil
                    && !alreadySigned
                    && (standing?.isActionable ?? false),
                canSubmit: standing == .ready
            ))
        }
        rows = built
    }

    // MARK: - Acting

    public func sign(_ id: UUID) async {
        busyProposalID = id
        actionError = nil
        defer { busyProposalID = nil }
        switch await signing.sign(proposalID: id) {
        case .signed:
            break
        case .needsExternalWallet(let request):
            walletRequest = request
            pasteTargetID = id
        case .notASigner:
            actionError = "You haven't chosen a Stellar account for this chat yet."
        case .expired:
            actionError = "This proposal has expired."
        case .superseded:
            actionError = "Another transaction went first. This one can no longer be used."
        case .failed(let reason):
            actionError = reason
        case .submitted, .notEnoughWeight:
            break
        }
    }

    public func submit(_ id: UUID) async {
        busyProposalID = id
        actionError = nil
        defer { busyProposalID = nil }
        switch await signing.submit(proposalID: id) {
        case .submitted:
            await loadHistory()
        case .notEnoughWeight(let weight, let required):
            actionError = "Still \(required - weight) signature(s) short."
        case .superseded:
            actionError = "Another transaction used this slot. Propose it again."
        case .expired:
            actionError = "This proposal has expired."
        case .failed(let reason):
            actionError = reason
        case .signed, .needsExternalWallet, .notASigner:
            break
        }
    }

    /// Take the signature out of an envelope pasted back from a wallet.
    public func adoptPasted() async {
        guard let id = pasteTargetID else { return }
        actionError = nil
        guard let returned = try? TransactionEnvelope(base64XDR: pastedXDR) else {
            actionError = "That doesn't look like a signed Stellar transaction."
            return
        }
        busyProposalID = id
        defer { busyProposalID = nil }
        switch await signing.adoptSignatures(fromReturned: returned, proposalID: id) {
        case .signed:
            pastedXDR = ""
            pasteTargetID = nil
        case .failed(let reason):
            actionError = reason
        default:
            break
        }
    }

    public func clearWalletRequest() { walletRequest = nil }
    public func clearError() { actionError = nil }

    // MARK: - Composing

    public func proposePayment() async {
        composeError = nil
        guard let destination = try? StellarAccountID(
            accountID: normalized(paymentDestination)
        ) else {
            composeError = "That isn't a valid Stellar account ID."
            return
        }
        guard let amount = try? StellarAmount(decimalString: paymentAmount.trimmed),
              amount.stroops > 0
        else {
            composeError = "Enter an amount to send."
            return
        }
        let asset: StellarAsset
        if paymentAssetCode.isEmpty || paymentAssetCode.uppercased() == "XLM" {
            asset = .native
        } else {
            guard let issuer = try? StellarAccountID(
                accountID: normalized(paymentAssetIssuer)
            ), let credit = try? StellarAsset(code: paymentAssetCode.trimmed, issuer: issuer)
            else {
                composeError = "That asset's issuer isn't a valid account ID."
                return
            }
            asset = credit
        }

        isComposing = true
        defer { isComposing = false }
        await handle(await proposing.proposePayment(
            groupID: groupID,
            destination: destination,
            asset: asset,
            amount: amount
        ))
    }

    public func proposeTrustline() async {
        composeError = nil
        guard let issuer = try? StellarAccountID(accountID: normalized(trustlineIssuer)),
              let asset = try? StellarAsset(code: trustlineCode.trimmed, issuer: issuer)
        else {
            composeError = "Enter an asset code and a valid issuer account."
            return
        }
        isComposing = true
        defer { isComposing = false }
        await handle(await proposing.proposeTrustline(groupID: groupID, asset: asset))
    }

    public func proposeAddSigner(_ account: StellarAccountID) async {
        composeError = nil
        isComposing = true
        defer { isComposing = false }
        await handle(await proposing.proposeAddSigner(groupID: groupID, newSigner: account))
    }

    private func handle(_ outcome: TreasuryProposalOutcome) async {
        switch outcome {
        case .proposed:
            paymentDestination = ""
            paymentAmount = ""
            paymentAssetCode = ""
            paymentAssetIssuer = ""
            trustlineCode = ""
            trustlineIssuer = ""
            composeError = nil
        case .noTreasury:
            composeError = "This chat has no treasury."
        case .notAMember:
            composeError = "You're not a member of this chat."
        case .sequenceContended:
            composeError = "There's already a proposal waiting. Only one can go through at a time \u{2014} finish or let that one lapse first."
        case .failed(let reason):
            composeError = reason
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Data {
    /// Local spelling so this file doesn't depend on the one in
    /// `TreasuryBroadcaster`, which is internal to `OnymTreasury`.
    var hexStringValue: String { map { String(format: "%02x", $0) }.joined() }
}
