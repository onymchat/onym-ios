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
    /// Weight per member, by roster key. Absent means one.
    public private(set) var weights: [String: UInt32] = [:]
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
        TreasurySignerSelection.spendableAmount(spendableField)
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
    /// Reconciliation reads a ledger, and snapshots arrive on every
    /// change; once per flow is enough to resolve a state that only
    /// changes when someone acts.
    private var hasReconciledStrandedFunding = false
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
        /// `network` is carried too, and read back on confirm. It is
        /// the network the envelope was *built for*, which the Settings
        /// toggle can no longer be relied on to name: a founder who
        /// switches between handing off and confirming would otherwise
        /// have the ledger check run against the wrong Horizon and be
        /// told their perfectly good treasury is not on the ledger.
        /// `request` is the SEP-0007 handoff, retained so the wallet
        /// can be opened again — `pendingWalletRequest` is cleared the
        /// moment the link is handed off, so without this the URL was
        /// gone and a wallet dismissed by accident could not be
        /// reopened. Nil after a relaunch: the envelope is not
        /// persisted, so a restored stage can confirm or discard but
        /// cannot re-offer the same transaction.
        case awaitingWallet(
            treasuryAccountID: String,
            creationTxHash: String,
            coSigners: [TreasuryCoSigner],
            thresholds: TreasuryThresholds,
            network: StellarNetwork,
            request: SEP0007Request?
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
    /// The live subscription — shared with `TreasuryProposalsFlow`, see
    /// `FlowSubscription`, because the same defect was found in one of
    /// these two flows and fixed only there three times running.
    private let subscription = FlowSubscription()
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
        network: @escaping @Sendable () -> StellarNetwork
    ) {
        self.groupID = groupID
        self.repository = repository
        self.groups = groups
        self.identity = identity
        self.broadcaster = broadcaster
        self.creation = creation
        self.network = network
    }

    /// Idempotent — the view calls it from `.task`, which re-runs on
    /// every re-identification of the view.
    public func start() async {
        await subscription.start { [weak self] in
            guard let self else { return }
            self.onymDerivedAccount = await (self.identity.currentIdentity()?
                .treasuryAccountID).flatMap { try? StellarAccountID(accountID: $0) }
            for await snapshot in self.repository.snapshots(groupID: self.groupID) {
                await self.apply(snapshot)
            }
        }
    }

    /// End the subscription — see `FlowSubscription.cancel()` for why a
    /// flow nobody references still has to be told to stop.
    /// `TreasuryFlowCache` calls this before dropping an entry;
    /// `ChatsFlow.stop()` exists for the same reason.
    public func stop() {
        subscription.cancel()
    }

    private func apply(_ snapshot: TreasurySnapshot) async {
        // Restored from disk, not held in memory. A creation handed to a
        // wallet outlives this process and this identity selection, and
        // losing it leaves a funded treasury the group is never told
        // about — see `PendingTreasuryCreation`.
        //
        // Only when this group has no treasury yet. A pending row can
        // outlive the handoff — the anchor arrives by broadcast, or a
        // second confirm returns `alreadyExists` — and restoring from it
        // then puts "waiting for your wallet" on a group that already
        // has one, on every launch. `snapshot.treasury` is the cheaper
        // and more direct guard than anything the row could carry.
        // An unreadable row is reported, not treated as no row: it may
        // hold a key for an account a wallet already funded, and
        // quietly showing the idle form over the top of it is how a
        // handoff gets forgotten.
        let pendingRow = try? await repository.pendingCreation(groupID: groupID)
        if pendingRow == nil,
           snapshot.treasury == nil,
           await repository.hasUnreadablePendingCreation(groupID: groupID) {
            creationError = String(
                localized: "A treasury handoff is saved on this phone and this version cannot read it. Nothing has been changed."
            )
        }
        if case .idle = creationStage,
           snapshot.treasury == nil,
           let pending = pendingRow {
            creationStage = .awaitingWallet(
                treasuryAccountID: pending.treasuryAccount.accountID,
                creationTxHash: pending.creationTxHash,
                coSigners: pending.coSigners,
                thresholds: pending.thresholds,
                network: pending.network,
                request: nil
            )
        }
        await reconcileStrandedFunding(snapshot)

        treasury = snapshot.treasury
        // Scoped to the owning identity. `currentGroups()` is every
        // cached group across *all* identities, so an unscoped lookup
        // could read `memberProfiles`, the name and the admin flag off
        // another identity's copy while the treasury snapshot is scoped
        // to the selected one — the roster and the co-signer list then
        // disagree with what `create()` validates.
        // `TreasuryCreationInteractor` guards the same case.
        guard let me = await identity.currentIdentity(),
              let owner = await identity.currentSelectedID(),
              let group = await groups.currentGroups().first(where: {
                  $0.id == groupID && $0.ownerIdentityID == owner
              })
        else { return }

        // After the guard, deliberately. Publishing ran before it, so a
        // group this identity does not own — one that fails the check
        // above — still had an address broadcast into it.
        await publishOnymAccountIfUndeclared(snapshot, me: me)
        loadAddressDisclosure()

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
        let previous = mine?.account
        mine = snapshot.declarations.first { $0.memberBlsPubkeyHex == myHex }
        // The funder card is drawn from `mine`, so re-declaring has to
        // move it. It used to refresh only from `.task`, which does not
        // re-run when the declaration changes underneath it.
        if mine?.account != previous { await refreshFunder() }

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

    /// Publish this member's Onym-derived account without being asked,
    /// so a founder does not meet a gate before they know what a
    /// treasury is.
    ///
    /// The old first screen said "Waiting for people to choose their
    /// accounts" and "Out of 0 co-signers": creation was blocked until
    /// every member separately completed a flow none of them had a
    /// reason to understand yet. The redesign's answer is that Onym
    /// already holds a Stellar account for everyone, so everyone can be
    /// on the list from the start.
    ///
    /// It has to happen here, on each member's own device, and that is
    /// not an implementation detail: the Onym account is HKDF-derived
    /// from that member's Nostr secret, so no other device — founder's
    /// included — can compute it. "Default to their Onym account" is
    /// only possible as "their device published it already", which is
    /// also what keeps the address signed by the person it belongs to
    /// rather than asserted by someone else.
    ///
    /// What it costs is stated where the person can act on it: their
    /// address becomes public, permanently, without them choosing. A
    /// member who wants a different wallet replaces it from the roster;
    /// one who wants off a treasury that already exists needs the
    /// group's agreement, because by then Stellar is holding the
    /// answer, not this app.
    private func publishOnymAccountIfUndeclared(
        _ snapshot: TreasurySnapshot,
        me: Identity
    ) async {
        // Against the snapshot, not against `mine`.
        //
        // `mine` is assigned further down this same function, so a
        // guard on it was reading the *previous* snapshot: every
        // snapshot arriving before a declaration round-tripped
        // re-broadcast it, and a member who had just chosen an external
        // wallet could have the Onym account published over the top of
        // it. The declarations in the snapshot are the answer to "has
        // this member already chosen", and they are in hand here.
        let myKey = me.blsPublicKey.hexString
        guard snapshot.declarations.first(where: {
            $0.memberBlsPubkeyHex.lowercased() == myKey.lowercased()
        }) == nil else { return }
        // And not into a treasury that already exists: its signer set
        // is fixed on the ledger, so a new declaration adds nobody and
        // publishes an address for nothing.
        guard snapshot.treasury == nil, let account = onymDerivedAccount else { return }
        _ = await broadcaster.declareSigner(
            groupIDHex: groupID,
            account: account,
            source: .onym
        )
    }

    public func declareOnymDerived() async {
        guard let account = onymDerivedAccount else {
            declarationError = String(localized: "This identity has no treasury key.")
            return
        }
        await declare(account: account, source: .onym)
    }

    public func declareExternal() async {
        guard let account = try? StellarAccountID(accountID: externalAccountField) else {
            declarationError = String(localized: "That is not a valid Stellar account ID.")
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
            declarationError = String(localized: "Couldn't record that account. Try again.")
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
        // Through the repository, which owns Horizon reads. A flow
        // reaching past it contradicts the invariant stated on
        // `TreasuryRepository`, and would be a second, uncached path to
        // the same third party.
        let account = await repository.account(mine.account, network: network())
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
        resolvedCoSignerSet.map(\.account)
    }

    /// The co-signers with their weights, which is what the transaction
    /// is built from and what every readout counts.
    public var resolvedCoSignerSet: [TreasuryCoSigner] {
        let accounts = TreasurySignerSelection.accounts(
            ticked: selectedCoSigners,
            from: members.map {
                ($0.blsPubkeyHex, $0.account ?? Self.placeholder, $0.standing.canBeNominated
                    && $0.account != nil)
            }
        )
        return accounts.map { account in
            let member = members.first { $0.account == account }
            let chosen = member.flatMap { weights[$0.blsPubkeyHex] }
            // A weight the domain refuses falls back to one rather than
            // dropping the person: the co-signer set is what the
            // founder ticked, and a signer vanishing because a stepper
            // produced an out-of-range number would be a worse lie than
            // a signer counted once.
            guard let chosen,
                  let weighted = TreasuryCoSigner(
                      account: account,
                      weight: chosen,
                      memberBlsPubkeyHex: member?.blsPubkeyHex
                  )
            else {
                return TreasuryCoSigner(
                    account: account,
                    memberBlsPubkeyHex: member?.blsPubkeyHex
                )
            }
            return weighted
        }
    }

    /// What it takes to spend, live, as a sentence about people.
    ///
    /// The old screen showed "1/1" twice and left the reader to work
    /// out what either number governed. This recomputes on every tap
    /// and is the thing the creation steps and the roster both lead
    /// with.
    public var quorum: TreasuryQuorum {
        TreasuryQuorum(
            coSigners: resolvedCoSignerSet,
            thresholds: TreasuryThresholds(
                low: 1,
                medium: mediumThreshold,
                high: highThreshold
            )
        )
    }

    /// Whether this device has shown the person what was published
    /// about them.
    ///
    /// Per group and per identity, because the address is published per
    /// group: being told once about Flat 4 says nothing about the next
    /// chat someone is quietly added to.
    public private(set) var hasSeenAddressDisclosure = false

    private var addressDisclosureKey: String {
        "treasury.address-disclosure.\(groupID).\(myBlsPubkeyHex ?? "unknown")"
    }

    public func acknowledgeAddressDisclosure() {
        hasSeenAddressDisclosure = true
        UserDefaults.standard.set(true, forKey: addressDisclosureKey)
    }

    private func loadAddressDisclosure() {
        hasSeenAddressDisclosure = UserDefaults.standard.bool(forKey: addressDisclosureKey)
    }

    /// Roster keys to names, so a quorum sentence can say "Aino"
    /// rather than "GBOIQE…". This is what `TreasuryCoSigner`'s roster
    /// key is carried for.
    public var memberNames: [String: String] {
        Dictionary(
            members.map { ($0.blsPubkeyHex, $0.alias) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// This device's own roster key, so the sentence can say "you".
    public var myBlsPubkeyHex: String? {
        members.first { $0.isSelf }?.blsPubkeyHex
    }

    /// What one person's signature counts for. One is the default and
    /// the only value the old design could express.
    public func weight(of member: TreasuryMemberRow) -> UInt32 {
        weights[member.blsPubkeyHex] ?? 1
    }

    public func setWeight(_ weight: UInt32, for member: TreasuryMemberRow) {
        weights[member.blsPubkeyHex] = min(max(weight, 1), TreasuryCoSigner.maximumWeight)
        clampThresholdsToWeight()
    }

    /// Thresholds follow the weights down.
    ///
    /// The steppers are independent, so lowering someone's weight can
    /// leave a bar above what the group adds up to — an account no
    /// quorum can ever act on, including to repair itself. Stellar
    /// accepts that; nobody can undo it.
    private func clampThresholdsToWeight() {
        let total = quorum.totalWeight
        guard total > 0 else { return }
        mediumThreshold = min(max(mediumThreshold, 1), total)
        highThreshold = min(max(highThreshold, mediumThreshold), total)
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
        clampThresholdsToWeight()
    }

    /// Keeps the thresholds inside what the resolved signer set can
    /// reach, and `high` at or above `medium`. Both are reachable in a
    /// couple of taps on screen and both are permanent — an account
    /// whose threshold exceeds its total weight can never act again,
    /// and one whose `high` is below its `medium` can be seized by any
     /// One clamp, and it counts weight.
    ///
    /// There were two: this one, against the headcount, and a
    /// weight-aware twin. `create()` used the twin; the steppers and
    /// the co-signer toggles — every control a founder actually touches
    /// — called this one, so each tap snapped the bar back to the
    /// number of people. Weights above 1 were settable and then
    /// immediately undone: "you and Aino together", two signers at 2
    /// with the bar at 4, could not be expressed at all.
    ///
    /// The twin is `clampThresholdsToWeight`, and it is now the only
    /// one. Two functions with one job is how the first version got
    /// converted and the second did not.
    public func thresholdsChanged() { clampThresholdsToWeight() }


    public func create() async {
        // The founder funds from the account they declared. Not from
        // some separate "funding account" field: a Stellar *signer* key
        // never needs a balance, so the Onym-derived one is empty by
        // default, and asking someone to first move money into a second
        // Onym-managed account before they can fund a third is a step
        // with no purpose. Whoever is going to co-sign already has to
        // name an account; that is the one with money in it.
        guard let mine else {
            creationError = String(localized: "Choose your own Stellar account first.")
            return
        }
        guard let spendable = spendableAmount else {
            creationError = String(localized: "That isn't an amount.")
            return
        }
        // Built from the resolved list, not the tick list — see
        // `resolvedCoSigners`. Clamping again here rather than trusting
        // the steppers: a member can leave the group or their
        // declaration can stop verifying between the last tap and this
        // moment, and the thresholds were chosen against the old count.
        let coSigners = resolvedCoSignerSet
        guard !coSigners.isEmpty else {
            creationError = String(localized: "Choose at least one co-signer.")
            return
        }
        // Clamped against the weights, not the headcount: with someone
        // at 2 the two numbers differ, and the ledger enforces the one
        // the signers add up to.
        clampThresholdsToWeight()
        let thresholds = TreasuryThresholds(
            low: 1,
            medium: mediumThreshold,
            high: highThreshold
        )
        guard TreasuryQuorum(coSigners: coSigners, thresholds: thresholds).isReachable else {
            creationError = String(
                localized: "Those numbers can't be met by the co-signers you chose."
            )
            return
        }

        isCreating = true
        creationError = nil
        defer { isCreating = false }

        // Read once and used for both the build and the stage that
        // outlives it: the Settings toggle is a live value, and a
        // transaction built for one network must never be confirmed
        // against another.
        let buildNetwork = network()
        let outcome = await creation.create(
            groupIDHex: groupID,
            funder: mine.account,
            coSigners: coSigners,
            thresholds: thresholds,
            spendable: spendable,
            network: buildNetwork
        )
        switch outcome {
        case .created:
            creationError = nil
            creationStage = .created
        case .alreadyExists:
            creationError = String(localized: "This chat already has a treasury.")
        case .fundedAnotherAccount:
            // `create` returns `.alreadyExists` long before it reaches
            // the external path, so this cannot happen here. Named
            // rather than defaulted, so adding a case stays a compiler
            // error somewhere useful.
            creationError = String(localized: "This chat already has a treasury.")
        case .notAdmin:
            creationError = String(localized: "Only the founder can create the treasury.")
        case .noDeclaredSigners:
            creationError = String(localized: "Nobody has chosen a Stellar account yet.")
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
                thresholds: thresholds,
                network: buildNetwork,
                request: request
            )
        case .failed(let reason):
            creationError = reason
        }
    }

    public func clearWalletRequest() { pendingWalletRequest = nil }

    /// Hand the same transaction to the wallet again.
    ///
    /// `clearWalletRequest()` runs as soon as the link is opened, so
    /// the URL was unrecoverable from that moment: a wallet dismissed
    /// by accident, or one that never came to the front, left the
    /// founder on a screen whose only button was "I've sent it" for a
    /// transaction they had not sent. Unavailable after a relaunch,
    /// because the envelope is not persisted — the stage says so by
    /// carrying a nil request rather than by offering a button that
    /// does nothing.
    public var canReopenWallet: Bool {
        if case .awaitingWallet(_, _, _, _, _, let request) = creationStage {
            return request != nil
        }
        return false
    }

    /// The transaction itself, base64 XDR, for a founder whose wallet
    /// will not finish the job.
    ///
    /// A handoff has two ends and this app controls one of them. When
    /// the far end stalls, the founder was left with a screen that
    /// could only wait. These bytes are the transaction that funds the
    /// account: one operation, unsigned, short exactly the founder's
    /// signature, and finishable in any tool that speaks Stellar.
    /// Locking the treasury down is a second transaction that never
    /// goes near a wallet.
    ///
    /// Nil after a relaunch, for the same reason `canReopenWallet` is:
    /// the envelope is not persisted.
    public var walletTransactionXDR: String? {
        guard case .awaitingWallet(_, _, _, _, _, let request) = creationStage else {
            return nil
        }
        return request?.envelope.base64XDR
    }

    /// When the handed-off transaction stops being submittable. Shown
    /// rather than left to be discovered: past it, wallets are entitled
    /// to refuse, and several do so without saying anything.
    public var walletDeadline: Date? {
        guard case .awaitingWallet(_, _, _, _, _, let request) = creationStage,
              let bounds = request?.envelope.transaction.timeBounds,
              bounds.maxTime != 0
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bounds.maxTime))
    }

    public func reopenWallet() {
        guard case .awaitingWallet(_, _, _, _, _, let request) = creationStage,
              let request
        else { return }
        pendingWalletRequest = request
    }

    /// Finish a handoff the create screen can no longer reach.
    ///
    /// When another admin's anchor lands mid-handoff, this group has a
    /// treasury and `CreateTreasuryView` stops being presented at all —
    /// so the one button that could finish the founder's funded account
    /// is gone, while the row and its key persist. That is the state
    /// `configureStrandedFunding` was written to resolve, reachable
    /// only if something outside the create screen triggers it.
    ///
    /// This is that trigger: opening the treasury screen. Once per flow,
    /// and only when a seeded row disagrees with the anchor, because a
    /// snapshot arrives on every change and this reads a ledger.
    private func reconcileStrandedFunding(_ snapshot: TreasurySnapshot) async {
        guard !hasReconciledStrandedFunding,
              let anchored = snapshot.treasury,
              let pending = try? await repository.pendingCreation(groupID: groupID),
              pending.treasurySeed != nil,
              pending.treasuryAccount != anchored.account
        else { return }
        hasReconciledStrandedFunding = true
        if case .fundedAnotherAccount(let account) = await creation
            .completeExternalCreation(groupIDHex: groupID) {
            creationError = String(
                localized: "This chat already has a treasury, so your funding went to a different account: \(account.abbreviated). It is now controlled by the same co-signers, who can move it."
            )
        }
    }

    /// Give up on a handoff — unless the wallet already funded it.
    ///
    /// The pending row is written before the wallet opens, and until a
    /// while ago nothing set `creationStage` back to `.idle`: a wallet
    /// that refused, an envelope that lapsed, or a founder who wanted
    /// different co-signers left the group pinned to "Waiting for your
    /// wallet" with one button that could only fail.
    ///
    /// What this is *not* is safe by construction. The doc here used to
    /// claim it was — nothing on-chain discarded, `adopt` would find the
    /// account, create again and it is confirmed — and the split made
    /// every clause of that false. The wallet only funds the account
    /// now; the key that configures it lives in the pending row and
    /// exists nowhere else. Once the funding lands, forgetting the row
    /// puts the founder's XLM beyond everyone, permanently.
    ///
    /// So the interactor decides, against the ledger, and this reports
    /// what it decided.
    public func abandonExternalCreation() async {
        switch await creation.abandonExternalCreation(groupIDHex: groupID) {
        case .discarded:
            pendingWalletRequest = nil
            creationError = nil
            creationStage = .idle
        case .accountAlreadyFunded:
            creationError = String(
                localized: "Your wallet already funded this treasury, so starting over would strand it. Tap \"I've sent it\" to finish setting it up."
            )
        case .couldNotTell:
            creationError = String(
                localized: "Couldn't reach the network to check whether your wallet already sent the funding. Nothing was changed \u{2014} try again in a moment."
            )
        }
    }

    /// After a wallet handoff: check the ledger and, if the account is
    /// there and configured as asked, anchor it and tell the group.
    ///
    /// The wallet's half was the funding. This runs the other half —
    /// the signers and the lockdown — and then verifies before
    /// believing: the account must exist, its master key must actually
    /// be switched off, its signers must be the ones this screen chose
    /// at the weights it chose, and the thresholds must be reachable by
    /// them. Taking anyone's word for it would mean anchoring a group
    /// to an account that might still be under one person's control.
    ///
    /// Re-runnable on purpose: every step reads the ledger and does only
    /// what is not yet done, so a second tap, a dead network or a
    /// relaunch resumes rather than repeats.
    public func confirmExternalCreation() async {
        // Only that the stage is the waiting one. What the handoff was
        // for lives in the persisted pending row, which is where the
        // interactor reads it — the stage's copy was a second source of
        // the same truth and is no longer consulted here.
        guard case .awaitingWallet = creationStage else { return }
        isCreating = true
        creationError = nil
        defer { isCreating = false }

        // The interactor owns what "finish this" means now: the wallet
        // only funded the account, and locking it down is this app's
        // half of the job. It reads the ledger before each step, so
        // tapping twice or coming back tomorrow resumes rather than
        // repeats — and it falls back to `adopt` for a handoff that
        // predates the split.
        let outcome = await creation.completeExternalCreation(groupIDHex: groupID)
        switch outcome {
        case .created:
            creationStage = .created
        case .alreadyExists:
            creationStage = .created
        case .failed(let reason):
            creationError = reason
        case .fundedAnotherAccount(let account):
            // Not "created", which is what this used to say for any
            // already-anchored group: the founder's money is in an
            // account that is not the treasury, and telling them it
            // exists would hide that. It has been configured to the
            // co-signers, so the same people can move it.
            creationStage = .idle
            creationError = String(
                localized: "This chat already has a treasury, so your funding went to a different account: \(account.abbreviated). It is now controlled by the same co-signers, who can move it."
            )
        case .notAdmin, .noDeclaredSigners, .needsExternalWallet:
            creationError = String(localized: "Couldn't confirm that treasury.")
        }
    }
}
