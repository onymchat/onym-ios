import Foundation
import OnymChain

/// Where one member stands on a group's rules, decided from what this
/// device holds about them.
///
/// The same question `JoinRequestApprover.RulesAgreement` answers for a
/// request that hasn't been accepted yet, asked again for a member who
/// is already in. It is a separate type because the answers differ: a
/// request cannot have been written by the founder, and a member cannot
/// be "an older client we could ask to upgrade" — they are in, and what
/// is left is what the stored bytes do or don't show.
///
/// Every case is derived by re-verifying, never by reading a flag: the
/// signature is checked against the text stored beside it each time
/// this is asked. A stored boolean would be a claim about a check
/// somebody once ran.
public enum GroupRulesStanding: Equatable, Sendable {
    /// The group asks nothing of anyone.
    case noRules
    /// The group has rules, and this kind of group has no way to agree
    /// to them: no join request, no approval, nobody to be the author.
    ///
    /// Not reachable today — `.tyranny` is the only governance type
    /// `CreateGroupFlow` will produce, and the other two cards are
    /// dimmed with a "Soon" pill — so this case exists to be correct
    /// when they ship rather than to fix a live bug. Without it,
    /// `.author` keyed on `adminPubkeyHex` (nil for both) would mark
    /// every member of an anarchy group, including whoever wrote the
    /// rules, as having declined to sign them.
    case notCollected
    /// This member wrote the rules. Founders don't sign their own
    /// terms, and rendering them as "didn't sign" would read as a
    /// failure rather than as the shape of the thing.
    case author
    /// Verified, against the rules the group holds now.
    case signed
    /// Verified — but over different words than the group's current
    /// rules. They agreed to an earlier version, which is a fact about
    /// the group's history rather than about this member.
    case signedEarlierVersion
    /// Nothing to check: they joined before the group had rules, or
    /// through a build that predates them.
    case didNotSign
    /// A stored signature this device cannot check, because it doesn't
    /// hold the wording the signature covers.
    ///
    /// Reachable, and not the same as `didNotSign`: an admitting device
    /// records the agreement with the rules as they stood, so a founder
    /// who clears the rules between a request and its approval produces
    /// exactly this — 64 bytes and nothing to check them against. Left
    /// in `didNotSign` it exported "joined before this group had
    /// rules", which is a claim, and a false one.
    ///
    /// Named for what is known rather than what it suggests, and
    /// deliberately the same name and wording as
    /// `JoinRequestApprover.RulesAgreement.unknownRules`: it is the
    /// same fact about the same bytes, one seen at approval and one
    /// seen afterwards.
    case unknownRules
    /// Bytes that don't verify against the text stored with them. Kept
    /// distinct from `didNotSign` because the two say different things
    /// about the same member, and only one of them is odd.
    case doesNotVerify

    /// True only where a signature was actually checked and passed.
    /// The mark on a row, and the `signed` field in an export, both
    /// come from here rather than from separate readings.
    public var isProven: Bool {
        switch self {
        case .signed, .signedEarlierVersion: true
        case .noRules, .notCollected, .author, .didNotSign, .unknownRules, .doesNotVerify:
            false
        }
    }
}

public extension ChatGroup {
    /// Where the member stored under `blsHex` stands on this group's
    /// rules.
    ///
    /// Takes the key rather than the profile, and looks the profile up
    /// here. Passing both let a caller hand over one member's profile
    /// under another's key — and since `adminPubkeyHex` is compared
    /// against that key, the mismatch that mattered was the one that
    /// returned `.author` for somebody else. The same argument
    /// `GroupRules.isAgreement` makes for taking the rules text rather
    /// than a hash: make the wrong pairing unsayable.
    ///
    /// `nil` when no member is stored under that key.
    func rulesStanding(ofMemberWith blsHex: String) -> GroupRulesStanding? {
        guard let member = memberProfiles[blsHex] else { return nil }
        return standing(of: member, blsHex: blsHex)
    }

    /// The stored bytes are read *before* the group's current state,
    /// because they outlive it.
    ///
    /// `invitationMessage` is a `var`. A founder who clears the rules
    /// would otherwise turn every agreement ever made into "this group
    /// asks nothing of anyone", and drop the signature, key and text
    /// from every export — deleting the evidence by editing a text
    /// field. What somebody signed happened; the group's present
    /// wording doesn't get a vote on it.
    private func standing(of member: MemberProfile, blsHex: String) -> GroupRulesStanding {
        let current = GroupRules.normalized(invitationMessage)
        if let signature = member.rulesSignature {
            guard let signedText = member.rulesText else { return .unknownRules }
            guard GroupRules.isAgreement(
                signature: signature,
                rules: signedText,
                groupID: groupIDData,
                joinerSendingPublicKey: member.sendingPubkey
            ) else { return .doesNotVerify }
            return signedText == current ? .signed : .signedEarlierVersion
        }
        guard current != nil else { return .noRules }
        // Asked after the stored bytes, so a signature made under a
        // governance type that later changed still reads honestly.
        guard groupType.collectsRulesAgreements else { return .notCollected }
        if let admin = adminPubkeyHex?.lowercased(), admin == blsHex.lowercased() {
            return .author
        }
        return .didNotSign
    }
}

extension SEPGroupType {
    /// Whether joining this kind of group passes through a request the
    /// founder approves — which is the only place an agreement to the
    /// rules is ever collected.
    ///
    /// Tyranny alone, and spelled out case by case rather than with a
    /// `default`: the wire enum carries five types, only one of which
    /// has an approval step to carry a signature or an admin to name as
    /// the rules' author. When one of the other four grows a joining
    /// ceremony, the compiler should make whoever builds it answer this
    /// question rather than inheriting a silent "no".
    var collectsRulesAgreements: Bool {
        switch self {
        case .tyranny: true
        case .anarchy, .oneOnOne, .democracy, .oligarchy: false
        }
    }
}
