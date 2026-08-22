import Foundation

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
    /// Bytes that don't verify. Kept distinct from `didNotSign`
    /// because the two say different things about the same member, and
    /// only one of them is odd.
    case doesNotVerify

    /// True only where a signature was actually checked and passed.
    /// The mark on a row, and the `signed` field in an export, both
    /// come from here rather than from separate readings.
    public var isProven: Bool {
        switch self {
        case .signed, .signedEarlierVersion: true
        case .noRules, .author, .didNotSign, .doesNotVerify: false
        }
    }
}

public extension ChatGroup {
    /// Where `member` stands on this group's rules.
    ///
    /// - Parameter blsHex: the member's key in `memberProfiles`, which
    ///   is also how `adminPubkeyHex` names the founder.
    func rulesStanding(of member: MemberProfile, blsHex: String) -> GroupRulesStanding {
        guard let current = GroupRules.normalized(invitationMessage) else { return .noRules }
        if let admin = adminPubkeyHex?.lowercased(), admin == blsHex.lowercased() {
            return .author
        }
        guard member.rulesSignature != nil, let signedText = member.rulesText else {
            return .didNotSign
        }
        guard member.agreedToRules(groupID: groupIDData) else { return .doesNotVerify }
        return signedText == current ? .signed : .signedEarlierVersion
    }
}
