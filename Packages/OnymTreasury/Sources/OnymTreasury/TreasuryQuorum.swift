import Foundation
import OnymStellar

/// One person on a treasury, and how far their signature carries.
///
/// Weight is Stellar's, and the design teaches the word rather than
/// hiding it — but every screen leads with what it means ("counts
/// double", "one signature") and the number follows. This type is the
/// domain half of that: it carries the account, the weight, and the
/// person, because a treasury screen that shows addresses where it
/// could show people is the thing being redesigned away.
public struct TreasuryCoSigner: Equatable, Sendable, Identifiable {
    public let account: StellarAccountID
    /// Stellar's cap, and the only ceiling this type imposes. It is
    /// not the enumeration cap: raising how many signers get a written
    /// sentence must not quietly raise how much one of them can count.
    public static let maximumWeight: UInt32 = 255

    /// How far this signature carries. Never zero — zero is not a
    /// light co-signer, it is how Stellar spells removal.
    public let weight: UInt32
    /// Roster key, for putting a face and a name on the row. Nil for a
    /// signer the ledger reports that this group cannot name.
    public let memberBlsPubkeyHex: String?

    public var id: String { account.accountID }

    /// A co-signer of weight one, which is the default and was the
    /// only thing the design before this could express.
    public init(account: StellarAccountID, memberBlsPubkeyHex: String? = nil) {
        self.account = account
        self.weight = 1
        self.memberBlsPubkeyHex = memberBlsPubkeyHex
    }

    /// Refused rather than clamped, for weights outside 1...255.
    ///
    /// The doc used to claim zero was refused while the code quietly
    /// turned it into one. That is the difference between a stale or
    /// hostile persisted row failing loudly and it silently becoming a
    /// signer — and it is why "weight 0 until confirmed", if it is ever
    /// chosen, has to be a state this type names rather than a number
    /// it swallows.
    public init?(
        account: StellarAccountID,
        weight: UInt32,
        memberBlsPubkeyHex: String? = nil
    ) {
        guard weight >= 1, weight <= Self.maximumWeight else { return nil }
        self.account = account
        self.weight = weight
        self.memberBlsPubkeyHex = memberBlsPubkeyHex
    }
}

/// What it takes to spend, said as a sentence about people.
///
/// This is the one piece of real logic the redesign asks for. Every
/// screen that sets weights or thresholds carries a live readout —
/// "You and Aino together — or either of you plus both Mira and Sam" —
/// and it has to recompute on every tap, be true, and never be a
/// fraction pretending to be a fact.
///
/// The arithmetic is subset-sum over the signer set. That is
/// exponential in principle and bounded in practice: Stellar allows at
/// most 20 signers on an account, and a treasury is a household or a
/// team. `maximumEnumerated` is the line past which this stops
/// enumerating and answers with the numbers alone, because a sentence
/// nobody can read is worse than "4 of 6".
public struct TreasuryQuorum: Equatable, Sendable {
    public let coSigners: [TreasuryCoSigner]
    public let thresholds: TreasuryThresholds

    /// Above this many signers the combinations are not enumerated.
    /// Twenty is Stellar's own ceiling; eight is where a sentence stops
    /// being a sentence.
    public static let maximumEnumerated = 8

    public init(coSigners: [TreasuryCoSigner], thresholds: TreasuryThresholds) {
        self.coSigners = coSigners
        self.thresholds = thresholds
    }

    /// Everything the co-signers add up to.
    public var totalWeight: UInt32 {
        UInt32(clamping: coSigners.reduce(UInt64(0)) { $0 + UInt64($1.weight) })
    }

    /// Whether this configuration can act at all.
    ///
    /// A threshold above the total weight is an account no quorum can
    /// ever satisfy — including to repair the threshold. Stellar will
    /// accept it; the group can never undo it.
    public var isReachable: Bool {
        !coSigners.isEmpty
            && thresholds.medium > 0
            && thresholds.high >= thresholds.medium
            && UInt64(thresholds.high) <= UInt64(totalWeight)
    }

    /// Whether every co-signer has to sign for anything to be spent.
    ///
    /// Arithmetic, not equality. The old test was `medium >= total`,
    /// which misses unanimity whenever the weights are uneven: two
    /// signers at 2 with the bar at 3 need both signatures, and
    /// `3 >= 4` is false. What makes it unanimous is that dropping the
    /// *lightest* signer already puts the rest under the bar.
    public var requiresEveryone: Bool {
        guard !coSigners.isEmpty else { return false }
        let lightest = coSigners.map(\.weight).min() ?? 0
        return totalWeight - lightest < thresholds.medium
    }

    /// The co-signers whose loss would freeze the treasury permanently.
    ///
    /// This is the fact the warning is actually about, and it is
    /// governed by `high`, not `medium`: a key is removed by changing
    /// the signer set, which the ledger charges at the high threshold —
    /// and it cannot be removed without its own signature. So the
    /// question is whether the *others* can still reach `high` without
    /// them. Three signers at 1 with high 3 is already the
    /// frozen-forever case, and the old check said nothing about it
    /// because it only compared `medium`.
    public var signersWhoseLossWouldFreezeIt: [TreasuryCoSigner] {
        coSigners.filter { totalWeight - $0.weight < thresholds.high }
    }

    /// The minimal sets of co-signers that reach `threshold`.
    ///
    /// Minimal, meaning no member of a returned set can be dropped and
    /// still clear the bar. Listing every superset would be true and
    /// useless: "you and Aino" already implies "you, Aino and Mira".
    /// Whether this signer set is small enough to be written out as a
    /// sentence. Past the ceiling the screens show the numbers — which
    /// is a different thing from saying nobody can reach the bar.
    public var isEnumerable: Bool {
        !coSigners.isEmpty && coSigners.count <= Self.maximumEnumerated
    }

    public func minimalCombinations(reaching threshold: UInt32) -> [[TreasuryCoSigner]] {
        guard !coSigners.isEmpty, threshold > 0,
              coSigners.count <= Self.maximumEnumerated,
              UInt64(threshold) <= UInt64(totalWeight)
        else { return [] }

        var reaching: [Set<Int>] = []
        let indices = Array(coSigners.indices)
        for mask in 1..<(1 << indices.count) {
            var sum: UInt64 = 0
            var members = Set<Int>()
            for index in indices where mask & (1 << index) != 0 {
                sum += UInt64(coSigners[index].weight)
                members.insert(index)
            }
            guard sum >= UInt64(threshold) else { continue }
            reaching.append(members)
        }
        // Keep only the sets that contain no other reaching set.
        let minimal = reaching.filter { candidate in
            !reaching.contains { other in other != candidate && other.isSubset(of: candidate) }
        }
        return minimal
            .sorted { ($0.count, $0.min() ?? 0) < ($1.count, $1.min() ?? 0) }
            .map { set in set.sorted().map { coSigners[$0] } }
    }

    /// Whether one co-signer can be outvoted — that is, whether any
    /// combination that clears the spending bar excludes them.
    ///
    /// The screens use this to say "no payment can happen without you
    /// or Aino", which is the fact a person reasons about when they are
    /// being asked to give up weight.
    public func canBeExcluded(_ coSigner: TreasuryCoSigner) -> Bool {
        minimalCombinations(reaching: thresholds.medium)
            .contains { !$0.contains(coSigner) }
    }
}
