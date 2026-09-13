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
    public var spendableField = "0"
    public var mediumThreshold: UInt32 = 1
    public var highThreshold: UInt32 = 1
    public private(set) var estimate: TreasuryFundingEstimate?
    public private(set) var isCreating = false
    public private(set) var creationError: String?
    /// Set when creation needs the founder's own wallet — the app
    /// cannot sign for an account it does not hold.
    public private(set) var pendingWalletRequest: SEP0007Request?

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
    private var started = false

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
        guard !started else { return }
        started = true
        onymDerivedAccount = await (identity.currentIdentity()?.treasuryAccountID)
            .flatMap { try? StellarAccountID(accountID: $0) }
        for await snapshot in repository.snapshots(groupID: groupID) {
            await apply(snapshot)
        }
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
        if selectedCoSigners.isEmpty {
            selectedCoSigners = Set(nominatable.map(\.blsPubkeyHex))
            let count = max(selectedCoSigners.count, 1)
            let defaults = TreasuryThresholds.majority(of: count)
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

    public func refreshEstimate() async {
        guard let spendable = try? StellarAmount(decimalString: spendableField) else {
            estimate = nil
            return
        }
        estimate = await creation.estimate(
            network: network(),
            signerCount: max(selectedCoSigners.count, 1),
            spendable: spendable
        )
    }

    public func toggle(_ member: TreasuryMemberRow) {
        if selectedCoSigners.contains(member.blsPubkeyHex) {
            selectedCoSigners.remove(member.blsPubkeyHex)
        } else {
            selectedCoSigners.insert(member.blsPubkeyHex)
        }
        // Keep the thresholds inside what the new set can actually
        // reach. A threshold above the total weight is an account
        // nobody can ever act on — reachable in two taps, and
        // permanent, so it is clamped rather than validated at submit.
        let count = UInt32(max(selectedCoSigners.count, 1))
        mediumThreshold = min(max(mediumThreshold, 1), count)
        highThreshold = min(max(highThreshold, 1), count)
    }

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
        guard let spendable = try? StellarAmount(decimalString: spendableField) else {
            creationError = "That isn't an amount."
            return
        }
        let coSigners = nominatable
            .filter { selectedCoSigners.contains($0.blsPubkeyHex) }
            .compactMap(\.account)
        guard !coSigners.isEmpty else {
            creationError = "Choose at least one co-signer."
            return
        }

        isCreating = true
        creationError = nil
        defer { isCreating = false }

        let outcome = await creation.create(
            groupIDHex: groupID,
            funder: mine.account,
            // An externally-held funding account means the app cannot
            // sign the creation envelope, so it goes out to the
            // founder's wallet instead — the `needsExternalWallet`
            // branch below.
            funderIsOnymDerived: mine.source == .onym,
            coSigners: coSigners,
            thresholds: TreasuryThresholds(
                low: 1,
                medium: mediumThreshold,
                high: highThreshold
            ),
            spendable: spendable,
            network: network()
        )
        switch outcome {
        case .created:
            creationError = nil
        case .alreadyExists:
            creationError = "This chat already has a treasury."
        case .notAdmin:
            creationError = "Only the founder can create the treasury."
        case .noDeclaredSigners:
            creationError = "Nobody has chosen a Stellar account yet."
        case .needsExternalWallet(let request, _):
            pendingWalletRequest = request
        case .failed(let reason):
            creationError = reason
        }
    }

    public func clearWalletRequest() { pendingWalletRequest = nil }
}
