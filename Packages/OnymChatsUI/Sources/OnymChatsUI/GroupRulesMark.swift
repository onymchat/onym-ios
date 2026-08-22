import SwiftUI
import OnymDesign
import OnymGroup

/// The mark beside a member's name, and the same words on their proof
/// sheet.
///
/// A small presentation type rather than a method on one of the two
/// screens that need it: a shared vocabulary living inside one of its
/// callers is a vocabulary waiting to be copied.
///
/// The strings are `ChatJoinRequestCell`'s own, not a matching set. A
/// member's standing and a request's verdict are the same fact at two
/// moments; near-duplicates would have given translators two of
/// everything to drift apart.
///
/// The failing cases read differently because they *are* different, and
/// the reader's next move differs with them: an unsigned request is
/// usually an older app; a signature over rules this device doesn't
/// hold can't be checked either way, so it claims nothing and is
/// coloured neutrally; a signature that fails against rules we do hold
/// is neither, and is the only one that should give anyone pause.
struct GroupRulesMark {
    let symbol: String
    let text: String
    let color: Color

    /// `nil` where the standing has nothing to report — see
    /// `GroupRulesStanding.hasSomethingToShow`, which is where that
    /// question lives now.
    init?(_ standing: GroupRulesStanding) {
        guard standing.hasSomethingToShow else { return nil }
        switch standing {
        case .noRules, .notCollected:
            return nil
        case .author:
            self.init(
                symbol: "pencil",
                text: String(localized: "Wrote the group rules"),
                color: OnymTokens.text2
            )
        case .signed:
            self.init(
                symbol: "checkmark.seal.fill",
                text: String(localized: "Signed the group rules"),
                color: OnymTokens.green
            )
        case .signedEarlierVersion:
            self.init(
                symbol: "clock.badge.checkmark",
                text: String(localized: "Signed an earlier version of the rules"),
                color: OnymTokens.text2
            )
        case .didNotSign:
            self.init(
                symbol: "minus.circle",
                text: String(localized: "Didn\u{2019}t sign the group rules"),
                color: OnymTokens.amber
            )
        case .unknownRules:
            self.init(
                symbol: "questionmark.circle",
                text: String(
                    localized: "Signed rules this device doesn\u{2019}t have \u{2014} can\u{2019}t be checked"
                ),
                color: OnymTokens.text2
            )
        case .doesNotVerify:
            self.init(
                symbol: "exclamationmark.triangle.fill",
                text: String(localized: "Signature on the rules doesn\u{2019}t check out"),
                color: OnymTokens.red
            )
        }
    }

    private init(symbol: String, text: String, color: Color) {
        self.symbol = symbol
        self.text = text
        self.color = color
    }
}

extension JoinRequestApprover.RulesAgreement {
    /// The same fact, in the vocabulary the member roster uses.
    ///
    /// A request's verdict and a member's standing are one thing seen
    /// at two moments, and the two screens were sharing the *keys* but
    /// not the literals — two `String(localized:)` sites for one
    /// sentence, which is one edit away from two catalog entries and a
    /// translator seeing them drift. The mapping is total and
    /// behaviour-preserving; the colours were already identical.
    var standing: GroupRulesStanding {
        switch self {
        case .notRequired: .noRules
        case .agreed: .signed
        case .unknownRules: .unknownRules
        case .notSigned: .didNotSign
        case .invalid: .doesNotVerify
        }
    }
}
