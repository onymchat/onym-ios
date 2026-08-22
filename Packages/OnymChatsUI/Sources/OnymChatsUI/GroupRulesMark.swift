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

    /// `nil` where there is no standing worth reporting: a group with
    /// no rules, or one whose kind collects no agreements. "Not
    /// applicable" on every row of every such group is noise, and the
    /// row keeps the BLS prefix it always showed.
    init?(_ standing: GroupRulesStanding) {
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
