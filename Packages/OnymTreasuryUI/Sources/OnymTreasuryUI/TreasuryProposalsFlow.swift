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

    /// History as events rather than hashes.
    ///
    /// Decoded from each transaction's own envelope — the only
    /// description of a transaction nobody could have written for us —
    /// and stored rather than computed on access. As a computed
    /// property every read re-decoded the whole history, and a
    /// `ForEach` that also reads `events.count` per row made one render
    /// n+1 full base64-plus-XDR passes over it.
    public private(set) var events: [TreasuryHistoryEvent] = []

    private func rebuildEvents() {
        guard let account = treasury?.account else {
            events = []
            return
        }
        events = history.map { TreasuryHistoryEvent($0, treasury: account) }
    }
    public private(set) var isLoadingHistory = false
    private var hasLoadedHistory = false
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
    /// Which surface's action failed — the alert is presented by that
    /// one, for the same reason the wallet link is.
    public private(set) var actionErrorSurface: Surface?
    public private(set) var busyProposalID: UUID?
    /// Which surface asked for the current signature.
    ///
    /// The thread block and the treasury screen observe the *same*
    /// memoised flow, and with the screen pushed from the thread both
    /// are in the hierarchy at once. Without this, one `walletRequest`
    /// assignment fired `openURL` from both — each `onChange` receives
    /// the new value directly, so clearing it afterwards deduplicates
    /// nothing — and both paste sheets went true, racing for one
    /// presentation. Each view now answers only for signatures it
    /// started.
    public enum Surface: Equatable, Sendable {
        case thread
        case screen
    }

    /// Set when signing needs the member's own wallet, together with
    /// the surface that asked. The matching view opens it and clears it.
    public private(set) var walletRequest: SEP0007Request?
    public private(set) var walletRequestSurface: Surface?
    /// Shown after a handoff: where the signed transaction comes back.
    public var pastedXDR = ""
    public var pasteTargetID: UUID?
    /// Failures from the paste sheet, shown inside it — see
    /// `PasteSignedTransactionView`.
    public private(set) var pasteError: String?

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
    /// The live subscription — shared with `TreasuryFlow`, see
    /// `FlowSubscription`, because the same defect was found in one of
    /// these two flows and fixed only there three times running.
    private let subscription = FlowSubscription()
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

    /// Whether this group has a treasury, without opening a
    /// subscription — see `TreasuryRepository.hasTreasury`.
    public func groupHasTreasury() async -> Bool {
        await repository.hasTreasury(groupID: groupID)
    }

    /// Idempotent — see `FlowSubscription.start`. Safe to call from
    /// every `.task` that shows this flow, however many times the
    /// thread's row is recycled and rebuilt.
    public func start() async {
        await subscription.start { [weak self] in
            guard let self else { return }
            // A live read before the first draw, so the screen does not
            // sit on "checking…" while a reachable network answers.
            await self.repository.refresh(groupID: self.groupID)
            for await snapshot in self.repository.snapshots(groupID: self.groupID) {
                await self.apply(snapshot)
            }
        }
    }

    /// End the subscription — see `FlowSubscription.cancel()`.
    /// `TreasuryProposalsFlowCache` calls this before dropping an entry.
    public func stop() {
        subscription.cancel()
    }

    public func refresh() async {
        await repository.refresh(groupID: groupID)
    }

    public func loadHistory() async {
        guard treasury != nil else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        history = await repository.history(groupID: groupID)
        rebuildEvents()
    }

    private func apply(_ snapshot: TreasurySnapshot) async {
        // Re-read per snapshot rather than once in `start()`. The flow
        // is cached for the app's lifetime, so a value read once was
        // the *previous* identity's key after a switch — and it is what
        // decides whether the Sign button is offered.
        myBlsHex = await identity.currentIdentity()?.blsPublicKey.hexString

        treasury = snapshot.treasury
        // The account decides direction for every payment in the list,
        // so the events are rebuilt when it arrives — not only when the
        // history does.
        rebuildEvents()
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

        // Loaded from here rather than a sibling `.task`. `loadHistory`
        // guards on `treasury != nil`, but that is only set after
        // `start()` finishes a network refresh and drains a snapshot —
        // so on a first visit the sibling ran too early, found nil, and
        // left the screen reading "Nothing has happened yet" until a
        // manual pull-to-refresh.
        if treasury != nil, history.isEmpty, !hasLoadedHistory {
            hasLoadedHistory = true
            await loadHistory()
        }

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

    public func sign(_ id: UUID, from surface: Surface) async {
        busyProposalID = id
        actionError = nil
        actionErrorSurface = surface
        defer { busyProposalID = nil }
        switch await signing.sign(proposalID: id) {
        case .signed:
            break
        case .needsExternalWallet(let request):
            walletRequest = request
            walletRequestSurface = surface
            pasteTargetID = id
            pasteSurface = surface
        case .notASigner:
            actionError = String(localized: "You haven't chosen a Stellar account for this chat yet.")
        case .expired:
            actionError = String(localized: "This proposal has expired.")
        case .superseded:
            actionError = String(
                localized: "Another transaction went first. This one can no longer be used."
            )
        case .failed(let reason):
            actionError = reason
        case .submitted, .notEnoughWeight:
            break
        }
    }

    public func submit(_ id: UUID, from surface: Surface) async {
        busyProposalID = id
        actionError = nil
        actionErrorSurface = surface
        defer { busyProposalID = nil }
        switch await signing.submit(proposalID: id) {
        case .submitted:
            await loadHistory()
        case .notEnoughWeight(let weight, let required):
            actionError = String(
                localized: "Still \(Int(required) - Int(weight)) signature(s) short."
            )
        case .superseded:
            actionError = String(
                localized: "Another transaction used this slot. Propose it again."
            )
        case .expired:
            actionError = String(localized: "This proposal has expired.")
        case .failed(let reason):
            actionError = reason
        case .signed, .needsExternalWallet, .notASigner:
            break
        }
    }

    /// Take the signature out of an envelope pasted back from a wallet.
    public func adoptPasted() async {
        guard let id = pasteTargetID else { return }
        pasteError = nil
        guard let returned = try? TransactionEnvelope(base64XDR: pastedXDR) else {
            pasteError = String(localized: "That doesn't look like a signed Stellar transaction.")
            return
        }
        busyProposalID = id
        defer { busyProposalID = nil }
        switch await signing.adoptSignatures(fromReturned: returned, proposalID: id) {
        case .signed:
            pastedXDR = ""
            pasteTargetID = nil
            pasteSurface = nil
            pasteError = nil
        case .failed(let reason):
            pasteError = reason
        default:
            break
        }
    }

    /// Set a proposal aside on this device, and put it back.
    ///
    /// Both are local and neither signs anything. The repository holds
    /// the reasoning: an open proposal claims the treasury's next
    /// sequence number, so one the group has decided against would
    /// otherwise block every other proposal until its time bound ran
    /// out.
    public func dismiss(_ id: UUID) async {
        await repository.dismiss(proposalID: id)
    }

    public func restore(_ id: UUID) async {
        await repository.restore(proposalID: id)
    }

    public func clearWalletRequest() {
        walletRequest = nil
        walletRequestSurface = nil
    }

    /// A wallet came back through `onym://tx`, and this flow may be the
    /// one waiting for it.
    ///
    /// Returns whether this flow took responsibility for telling the
    /// person what happened. It matters because the app's alert is
    /// attached at the root and the paste sheet is *always* on screen
    /// on this path — `sign()` sets `pasteTargetID` before opening the
    /// wallet link, and `ownsPastePrompt` goes true the moment the link
    /// is handed off. An alert underneath a sheet cannot present, so
    /// both outcomes were swallowed in silence. Whichever flow owns the
    /// sheet answers here instead: success dismisses it, failure shows
    /// the reason inside it.
    @discardableResult
    public func returnedFromWallet(adoptedProposalID: UUID?) -> Bool {
        guard pasteTargetID != nil else { return false }
        guard adoptedProposalID == pasteTargetID else { return false }
        pastedXDR = ""
        pasteTargetID = nil
        pasteSurface = nil
        pasteError = nil
        return true
    }

    /// Nothing anywhere took the returned envelope — tell the person
    /// waiting on this sheet, if there is one.
    ///
    /// Separate from the success path, and called only after every flow
    /// has been offered the adoption, because the app holds one flow per
    /// group: reporting "didn't match this proposal" on every open sheet
    /// the moment one of them succeeded would tell a co-signer their
    /// signature failed in one chat because it succeeded in another.
    @discardableResult
    public func walletReturnWentNowhere() -> Bool {
        guard pasteTargetID != nil else { return false }
        pasteError = String(
            localized: "That signed transaction didn't match this proposal. It may have already gone through, or expired."
        )
        return true
    }

    /// Whether `surface` is the one that should present the paste sheet
    /// — the surface that asked, and only once the wallet link has been
    /// handed off.
    public func ownsPastePrompt(_ surface: Surface) -> Bool {
        pasteTargetID != nil && walletRequest == nil && pasteSurface == surface
    }

    /// Remembered across `clearWalletRequest()`, which runs as soon as
    /// the link is opened while the paste sheet is still owed.
    public private(set) var pasteSurface: Surface?
    public func clearError() {
        actionError = nil
        actionErrorSurface = nil
    }

    /// The message `surface` should show, if any.
    public func error(for surface: Surface) -> String? {
        actionErrorSurface == surface ? actionError : nil
    }

    // MARK: - Composing

    public func proposePayment() async {
        composeError = nil
        guard let destination = try? StellarAccountID(
            accountID: normalized(paymentDestination)
        ) else {
            composeError = String(localized: "That isn't a valid Stellar account ID.")
            return
        }
        guard let amount = try? StellarAmount(decimalString: paymentAmount.trimmed),
              amount.stroops > 0
        else {
            composeError = String(localized: "Enter an amount to send.")
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
                composeError = String(localized: "That asset's issuer isn't a valid account ID.")
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
            composeError = String(localized: "Enter an asset code and a valid issuer account.")
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
            composeError = String(localized: "This chat has no treasury.")
        case .notAMember:
            composeError = String(localized: "You're not a member of this chat.")
        case .sequenceContended:
            composeError = String(
                localized: "There's already a proposal waiting. Only one can go through at a time \u{2014} finish or let that one lapse first."
            )
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
