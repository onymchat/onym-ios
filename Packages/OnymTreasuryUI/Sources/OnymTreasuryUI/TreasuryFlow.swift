import Foundation
import Observation
import OnymGroup
import OnymIdentity
import OnymFoundation
import OnymStellar
import OnymTreasury

/// One member as the treasury screens need them: who they are, and
/// whether they have said which Stellar account should speak for them.
public struct TreasuryMemberRow: Identifiable, Equatable, Sendable {
    public let blsPubkeyHex: String
    public let alias: String
    public let isSelf: Bool
    public let standing: TreasurySignerStanding
    public let account: StellarAccountID?

    public var id: String { blsPubkeyHex }

    public init(
        blsPubkeyHex: String,
        alias: String,
        isSelf: Bool,
        standing: TreasurySignerStanding,
        account: StellarAccountID?
    ) {
        self.blsPubkeyHex = blsPubkeyHex
        self.alias = alias
        self.isSelf = isSelf
        self.standing = standing
        self.account = account
    }
}

/// Screen state for declaring a signer and creating a treasury.
///
/// Flow-shaped in the way the architecture asks for: it owns transient
/// UI state — field contents, which step, whether something is in
/// flight, the last error — and nothing durable. Every fact about the
/// treasury arrives by draining `TreasuryRepository.snapshots`.
@Observable
@MainActor
public final class TreasuryFlow {
    // MARK: - Inputs

    public let groupID: String

    // MARK: - Observed state

    public private(set) var treasury: Treasury?
    public private(set) var members: [TreasuryMemberRow] = []
    /// This identity's own declaration, if it has made one.
    public private(set) var mine: TreasurySignerDeclarationRecord?
    public private(set) var isAdmin = false
    public private(set) var groupName = ""

    // MARK: - Declaration screen

    /// The account this identity would declare if it used its Onym key.
    /// Shown rather than hidden: a person choosing between "the one
    /// Onym derives for me" and "one I already have" should be able to
    /// see both addresses before deciding.
    public private(set) var onymDerivedAccount: StellarAccountID?
    public var externalAccountField = "" {
        didSet {
            let cleaned = externalAccountField
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if cleaned != externalAccountField { externalAccountField = cleaned }
            declarationError = nil
        }
    }
    public private(set) var declarationError: String?
    public private(set) var isDeclaring = false

    /// Whether what has been typed is a well-formed account ID,
    /// checksum included. Drives the field's own chip, so a typo is
    /// caught while the person is still looking at it.
    public var externalAccountIsValid: Bool {
        StellarStrKey.isValidAccountID(externalAccountField)
    }

    // MARK: - Creation screen

    /// Members the founder has chosen to hand control to. Seeded with
    /// everyone who has declared, because the ordinary case is "all of
    /// us" and un-ticking is easier than ticking.
    public var selectedCoSigners: Set<String> = []
    /// Empty reads as zero. `StellarAmount(decimalString:)` rejects ""
    /// and "1.", so clearing the field or typing a decimal point made
    /// the whole funding breakdown vanish mid-keystroke, and an empty
    /// field failed `create()` with "That isn't an amount" rather than
    /// meaning "no spendable balance", which is a perfectly ordinary
    /// thing to want.
    public var spendableField = "0"

    /// What `spendableField` means, with the half-typed states a text
    /// field legitimately passes through treated as zero.
    var spendableAmount: StellarAmount? {
        let trimmed = spendableField.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." { return StellarAmount(stroops: 0) }
        if trimmed.hasSuffix(".") {
            return try? StellarAmount(decimalString: String(trimmed.dropLast()))
        }
        return try? StellarAmount(decimalString: trimmed)
    }
    public var mediumThreshold: UInt32 = 1
    public var highThreshold: UInt32 = 1
    public private(set) var estimate: TreasuryFundingEstimate?
    /// The account creation will debit, and what it currently holds.
    ///
    /// The screen itemises "You send N XLM" and never said *from
    /// where*. The funder is silently the declared account, and for the
    /// option the declaration screen lists first — the Onym-derived one
    /// — that account is empty by construction, so creation failed on
    /// the Horizon read with an unexplained "could not read the funding
    /// account". On a screen whose whole thesis is telling the founder
    /// what they are giving up, the address being debited belongs on it.
    public private(set) var funderAccount: StellarAccountID?
    public private(set) var funderBalance: StellarAmount?
    /// Set when the funding account does not exist on the ledger yet,
    /// which on Stellar is what "unfunded" looks like.
    public private(set) var funderIsUnfunded = false
    public private(set) var isCreating = false
    public private(set) var creationError: String?
    /// Set when creation needs the founder's own wallet — the app
    /// cannot sign for an account it does not hold.
    public private(set) var pendingWalletRequest: SEP0007Request?
    /// Where creation has got to. The screen used to end at
    /// `creationError = nil` on success and at nothing at all on the
    /// wallet handoff: the founder was left looking at an enabled
    /// "Create the treasury" button with no signal either way.
    public private(set) var creationStage: CreationStage = .idle

    public enum CreationStage: Equatable, Sendable {
        case idle
        /// Handed to the founder's wallet, waiting for them to sign and
        /// submit it there. `treasuryAccountID` is the account the
        /// envelope creates, kept so `confirmExternalCreation()` can
        /// check the ledger for it afterwards; `creationTxHash` is the
        /// transaction the wallet will submit, kept so the anchor the
        /// group receives names something it can look up; and
        /// `thresholds` so the ledger check covers the whole
        /// configuration rather than only the signer keys.
        case awaitingWallet(
            treasuryAccountID: String,
            creationTxHash: String,
            coSigners: [StellarAccountID],
            thresholds: TreasuryThresholds
        )
        case created
    }

    /// Candidates for the signer set: everyone whose declaration this
    /// device could verify.
    public var nominatable: [TreasuryMemberRow] {
        members.filter { $0.standing.canBeNominated }
    }

    /// True when any chosen co-signer holds their account outside Onym
    /// and has never demonstrated control of it. Not an error — it is
    /// the ordinary state for exactly the people this feature exists
    /// for — but the creation screen says so, because an account nobody
    /// can sign with is how a treasury deadlocks.
    public var hasUnprovenCoSigners: Bool {
        nominatable.contains {
            selectedCoSigners.contains($0.blsPubkeyHex)
                && $0.standing == .declaredExternalUnproven
        }
    }

    // MARK: - Collaborators

    private let repository: TreasuryRepository
    private let groups: GroupRepository
    private let identity: IdentityRepository
    private let broadcaster: TreasuryBroadcaster
    private let creation: TreasuryCreationInteractor
    private let network: @Sendable () -> StellarNetwork
    private let horizon: @Sendable (StellarNetwork) -> any HorizonClient
    /// The live subscription, if one is draining.
    ///
    /// Not a `started` bool. The flow is memoised for the app's
    /// lifetime, and `start()` consumed the stream inline on the view's
    /// `.task` — so popping the treasury screen cancelled the task, the
    /// iteration ended, and the flag stayed true. Every later visit then
    /// rendered state frozen at the moment of the last exit: other
    /// members' declarations, the anchor broadcast, `mine` after a
    /// re-declaration, none of it arriving. Same defect as the one
    /// found in `TreasuryProposalsFlow`; it was here too and I missed
    /// it. Every other flow in the app (`ChatsFlow`, `PendingChatsFlow`,
    /// `ModerationSettingsFlow`) spawns a detached task and guards on
    /// it being nil, for exactly this reason.
    private var subscription: Task<Void, Never>?
    /// Seeded once. Keying the seed off `selectedCoSigners.isEmpty`
    /// meant unticking the last co-signer silently re-ticked everyone
    /// on the next snapshot — which arrives whenever anybody in the
    /// group declares an account.
    private var hasSeededSelection = false
    /// Network parameters for the screen's lifetime. They do not change
    /// between keystrokes, and the estimate is refreshed on every one.
    private var cachedParameters: TreasuryFundingEstimate?

    public init(
        groupID: String,
        repository: TreasuryRepository,
        groups: GroupRepository,
        identity: IdentityRepository,
        broadcaster: TreasuryBroadcaster,
        creation: TreasuryCreationInteractor,
        network: @escaping @Sendable () -> StellarNetwork,
        horizon: @escaping @Sendable (StellarNetwork) -> any HorizonClient = { network in
            URLSessionHorizonClient(network: network)
        }
    ) {
        self.groupID = groupID
        self.repository = repository
        self.groups = groups
        self.identity = identity
        self.broadcaster = broadcaster
        self.creation = creation
        self.network = network
        self.horizon = horizon
    }

    /// Idempotent — the view calls it from `.task`, which re-runs on
    /// every re-identification of the view.
    public func start() async {
        guard subscription == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.onymDerivedAccount = await (self.identity.currentIdentity()?
                .treasuryAccountID).flatMap { try? StellarAccountID(accountID: $0) }
            for await snapshot in self.repository.snapshots(groupID: self.groupID) {
                await self.apply(snapshot)
            }
        }
        subscription = task
        await task.value
    }

    /// End the subscription.
    ///
    /// Needed because the task deliberately outlives the view: it holds
    /// the flow strongly while it drains a stream that never finishes on
    /// its own, so a flow nobody references any more stays alive and
    /// subscribed for the rest of the run — still waking on every
    /// snapshot, still reading the group and identity repositories on
    /// the main actor. `TreasuryFlowCache` calls this before dropping an
    /// entry; `ChatsFlow.stop()` exists for the same reason.
    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    private func apply(_ snapshot: TreasurySnapshot) async {
        treasury = snapshot.treasury
        guard let group = await groups.currentGroups().first(where: { $0.id == groupID }),
              let me = await identity.currentIdentity()
        else { return }

        groupName = group.name
        isAdmin = group.isAdmin(blsPublicKey: me.blsPublicKey)
        let myHex = me.blsPublicKey.map { String(format: "%02x", $0) }.joined()
        let groupIDBytes = group.groupIDData

        members = group.memberProfiles
            .map { key, profile in
                let record = snapshot.declarations.first { $0.memberBlsPubkeyHex == key }
                return TreasuryMemberRow(
                    blsPubkeyHex: key,
                    alias: profile.alias,
                    isSelf: key == myHex,
                    standing: record?.standing(groupID: groupIDBytes) ?? .notDeclared,
                    account: record?.account
                )
            }
            // Self first, then alphabetically — the same ordering the
            // roster uses, so the two screens do not disagree about
            // where someone is.
            .sorted { lhs, rhs in
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
            }
        mine = snapshot.declarations.first { $0.memberBlsPubkeyHex == myHex }

        // Seed the signer set once, then leave the founder's choices
        // alone — re-seeding on every snapshot would undo a tick the
        // moment anyone else's declaration arrived.
        if !hasSeededSelection, !nominatable.isEmpty {
            hasSeededSelection = true
            selectedCoSigners = Set(nominatable.map(\.blsPubkeyHex))
            let defaults = TreasuryThresholds.majority(of: resolvedCoSigners.count)
            mediumThreshold = defaults.medium
            highThreshold = defaults.high
        }
    }

    // MARK: - Declaration intents

    public func declareOnymDerived() async {
        guard let account = onymDerivedAccount else {
            declarationError = "This identity has no treasury key."
            return
        }
        await declare(account: account, source: .onym)
    }

    public func declareExternal() async {
        guard let account = try? StellarAccountID(accountID: externalAccountField) else {
            declarationError = "That is not a valid Stellar account ID."
            return
        }
        await declare(account: account, source: .external)
    }

    private func declare(account: StellarAccountID, source: TreasurySignerSource) async {
        isDeclaring = true
        declarationError = nil
        defer { isDeclaring = false }
        let ok = await broadcaster.declareSigner(
            groupIDHex: groupID,
            account: account,
            source: source
        )
        if !ok {
            declarationError = "Couldn't record that account. Try again."
        } else {
            externalAccountField = ""
        }
    }

    // MARK: - Creation intents

    /// Recomputed on every keystroke in the amount field, so the
    /// network round trip behind it is made once and reused. Base fee
    /// and base reserve are protocol parameters; they do not change
    /// between two characters of a number.
    /// Reads the funding account so the screen can name it and say
    /// whether it can actually pay.
    public func refreshFunder() async {
        guard let mine else {
            funderAccount = nil
            return
        }
        funderAccount = mine.account
        let account = try? await horizon(network()).account(mine.account)
        funderIsUnfunded = account == nil
        funderBalance = account?.balances
            .first { $0.asset == .native }?
            .balance
    }

    public func refreshEstimate() async {
        guard let spendable = spendableAmount else {
            estimate = nil
            return
        }
        let signerCount = max(resolvedCoSigners.count, 1)
        if let cached = cachedParameters, cached.signerCount == signerCount {
            estimate = TreasuryFundingEstimate(
                minimumBalance: cached.minimumBalance,
                spendable: spendable,
                fee: cached.fee,
                baseReserve: cached.baseReserve,
                signerCount: signerCount
            )
            return
        }
        let fresh = await creation.estimate(
            network: network(),
            signerCount: signerCount,
            spendable: spendable
        )
        cachedParameters = fresh
        estimate = fresh
    }

    /// The accounts the creation transaction will actually install —
    /// deduplicated, and filtered to declarations this device can still
    /// verify. Not the same length as `selectedCoSigners`, which is why
    /// every threshold decision is taken from this.
    public var resolvedCoSigners: [StellarAccountID] {
        TreasurySignerSelection.accounts(
            ticked: selectedCoSigners,
            from: members.map {
                ($0.blsPubkeyHex, $0.account ?? Self.placeholder, $0.standing.canBeNominated
                    && $0.account != nil)
            }
        )
    }

    /// Never used — `nominatable` is false whenever the account is nil,
    /// so this stands in only to keep the tuple non-optional.
    private static let placeholder: StellarAccountID = {
        // swiftlint:disable:next force_try
        try! StellarAccountID(publicKey: Data(repeating: 0, count: 32))
    }()

    public func toggle(_ member: TreasuryMemberRow) {
        if selectedCoSigners.contains(member.blsPubkeyHex) {
            selectedCoSigners.remove(member.blsPubkeyHex)
        } else {
            selectedCoSigners.insert(member.blsPubkeyHex)
        }
        clampThresholds()
    }

    /// Keeps the thresholds inside what the resolved signer set can
    /// reach, and `high` at or above `medium`. Both are reachable in a
    /// couple of taps on screen and both are permanent — an account
    /// whose threshold exceeds its total weight can never act again,
    /// and one whose `high` is below its `medium` can be seized by any
    /// single co-signer. See `TreasurySignerSelection.clamped`.
    private func clampThresholds() {
        let clamped = TreasurySignerSelection.clamped(
            TreasuryThresholds(low: 1, medium: mediumThreshold, high: highThreshold),
            signerCount: resolvedCoSigners.count
        )
        mediumThreshold = clamped.medium
        highThreshold = clamped.high
    }

    /// Called by the steppers, which move one value at a time and can
    /// therefore push `high` below `medium` on their own.
    public func thresholdsChanged() { clampThresholds() }

    public func create() async {
        // The founder funds from the account they declared. Not from
        // some separate "funding account" field: a Stellar *signer* key
        // never needs a balance, so the Onym-derived one is empty by
        // default, and asking someone to first move money into a second
        // Onym-managed account before they can fund a third is a step
        // with no purpose. Whoever is going to co-sign already has to
        // name an account; that is the one with money in it.
        guard let mine else {
            creationError = "Choose your own Stellar account first."
            return
        }
        guard let spendable = spendableAmount else {
            creationError = "That isn't an amount."
            return
        }
        // Built from the resolved list, not the tick list — see
        // `resolvedCoSigners`. Clamping again here rather than trusting
        // the steppers: a member can leave the group or their
        // declaration can stop verifying between the last tap and this
        // moment, and the thresholds were chosen against the old count.
        let coSigners = resolvedCoSigners
        guard !coSigners.isEmpty else {
            creationError = "Choose at least one co-signer."
            return
        }
        let thresholds = TreasurySignerSelection.clamped(
            TreasuryThresholds(low: 1, medium: mediumThreshold, high: highThreshold),
            signerCount: coSigners.count
        )
        guard TreasurySignerSelection.isUsable(thresholds, signerCount: coSigners.count) else {
            creationError = "Those numbers can't be met by the co-signers you chose."
            return
        }
        mediumThreshold = thresholds.medium
        highThreshold = thresholds.high

        isCreating = true
        creationError = nil
        defer { isCreating = false }

        let outcome = await creation.create(
            groupIDHex: groupID,
            funder: mine.account,
            coSigners: coSigners,
            thresholds: thresholds,
            spendable: spendable,
            network: network()
        )
        switch outcome {
        case .created:
            creationError = nil
            creationStage = .created
        case .alreadyExists:
            creationError = "This chat already has a treasury."
        case .notAdmin:
            creationError = "Only the founder can create the treasury."
        case .noDeclaredSigners:
            creationError = "Nobody has chosen a Stellar account yet."
        case .needsExternalWallet(let request, let treasuryAccountID, let creationTxHash):
            // The wallet signs and submits; nothing is anchored until
            // the founder comes back and `confirmExternalCreation`
            // finds the account on the ledger. Previously this opened
            // the URL and ended — the group never learned the treasury
            // existed, and the screen looked like nothing had happened.
            pendingWalletRequest = request
            creationStage = .awaitingWallet(
                treasuryAccountID: treasuryAccountID,
                creationTxHash: creationTxHash,
                coSigners: coSigners,
                thresholds: thresholds
            )
        case .failed(let reason):
            creationError = reason
        }
    }

    public func clearWalletRequest() { pendingWalletRequest = nil }

    /// After a wallet handoff: check the ledger and, if the account is
    /// there and configured as asked, anchor it and tell the group.
    ///
    /// `adopt` verifies before believing — the account must exist, its
    /// master key must actually be switched off, and its signer set
    /// must be the one this screen chose. Taking the founder's word for
    /// it would mean anchoring a group to an account that might still
    /// be under one person's control.
    ///
    /// The rest of the group cannot run that check for themselves, so
    /// the anchor they receive has to carry the creation transaction —
    /// which is the envelope handed to the wallet, whose hash is fixed
    /// before it is signed.
    public func confirmExternalCreation() async {
        guard case .awaitingWallet(
            let accountID,
            let creationTxHash,
            let coSigners,
            let thresholds
        ) = creationStage else { return }
        isCreating = true
        creationError = nil
        defer { isCreating = false }

        let outcome = await creation.adopt(
            groupIDHex: groupID,
            treasuryAccountID: accountID,
            creationTxHash: creationTxHash,
            network: network(),
            expectedCoSigners: coSigners,
            expectedThresholds: thresholds
        )
        switch outcome {
        case .created:
            creationStage = .created
        case .alreadyExists:
            creationStage = .created
        case .failed(let reason):
            creationError = reason
        case .notAdmin, .noDeclaredSigners, .needsExternalWallet:
            creationError = "Couldn't confirm that treasury."
        }
    }
}
