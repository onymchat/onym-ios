import Foundation
import CryptoKit

/// One member's agreement to a group's rules, as a file that can leave
/// the device and still mean something.
///
/// ## What makes it a proof
///
/// Not this app's say-so. The document carries the exact inputs to the
/// check — the rules text, the member's Ed25519 public key, and their
/// signature — so a reader who trusts none of this can recompute
/// `GroupRules.statement(...)` and verify it with any Ed25519
/// implementation. The `_readme` lines say how, in the file itself,
/// because a proof whose verification procedure lives in a codebase the
/// reader doesn't have is a screenshot with extra steps.
///
/// ## The rules it carries are the signed ones
///
/// `rules` is the text stored beside the signature, not whatever the
/// group says today. Those differ exactly when the founder changed the
/// wording after this member joined, and the honest export is the one
/// whose bytes verify — with `matches_current_rules` naming the
/// divergence rather than hiding it.
///
/// ## What it deliberately doesn't carry
///
/// No group secret, no member roster, no inbox keys. A proof of
/// agreement should be showable to an outsider — a moderator, a
/// landlord, a court — without also handing them the ability to read
/// the group or find the people in it. The sending public key is
/// already public by construction (it verifies every message this
/// member sends) and the signature is meaningless without it.
public struct GroupRulesProof: Equatable, Sendable {
    public let groupIDHex: String
    public let groupName: String
    public let memberAlias: String
    public let memberBlsHex: String
    /// Nil when there is nothing to prove — see `standing`.
    public let sendingPublicKey: Data?
    public let signature: Data?
    /// The text the signature covers, which is the text that was on
    /// screen when this member agreed.
    public let rules: String?
    /// The rules the group holds now, for the reader to compare.
    public let currentRules: String?
    public let standing: GroupRulesStanding

    /// `nil` when no member is stored under `blsHex` — the same reason
    /// `rulesStanding(ofMemberWith:)` takes the key alone: a proof
    /// about a profile that isn't in this group's roster is a document
    /// nobody should be able to produce by accident.
    public init?(group: ChatGroup, blsHex: String) {
        guard let member = group.memberProfiles[blsHex],
              let standing = group.rulesStanding(ofMemberWith: blsHex)
        else { return nil }
        // Re-hexed from the bytes signing actually used, rather than
        // echoing `group.id`. `bytes(fromHex:)` is lenient, and the
        // `_readme` tells the reader this field is 32 bytes — a
        // malformed id would otherwise ship instructions that cannot be
        // followed.
        self.groupIDHex = group.groupIDData.hexString
        self.groupName = group.name
        self.memberAlias = member.alias
        self.memberBlsHex = blsHex
        self.standing = standing
        let currentRules = GroupRules.normalized(group.invitationMessage)
        self.currentRules = currentRules
        // Only carried where they mean something. Shipping a signature
        // that doesn't verify, or one there is no text for, would put
        // bytes in a document called a proof that prove nothing.
        if standing.isProven {
            self.sendingPublicKey = member.sendingPubkey
            self.signature = member.rulesSignature
            self.rules = member.rulesText
        } else {
            self.sendingPublicKey = nil
            self.signature = nil
            // The author is the one unproven standing with words worth
            // carrying: they are the group's rules, and a document
            // about the person who wrote them that contains none of
            // them is thin to the point of useless.
            self.rules = standing == .author ? currentRules : nil
        }
    }

    /// A filename someone can find again in a Files app six months
    /// later: the group and the member, not a hash.
    public var suggestedFileName: String {
        // A fixed locale, not the device's: `lowercased()` under a
        // Turkish locale maps I to a dotless ı, so the same group would
        // produce different filenames on two phones. And ASCII only —
        // diacritic folding leaves CJK and Cyrillic untouched, so
        // testing for "is a letter" would let them through into a name
        // that is meant to survive being emailed around.
        let stem = "\(groupName)-\(memberAlias)"
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { out, character in
                // Collapse runs, so "Maple  Garden!" doesn't become
                // "maple--garden-".
                if character == "-", out.last == "-" { return }
                out.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let named = stem.isEmpty ? "group-rules" : stem
        return "onym-rules-proof-\(named).json"
    }

    /// The file's bytes: pretty-printed, key-ordered JSON, so two
    /// exports of the same agreement are byte-identical and a diff
    /// between them means something changed.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    // MARK: - Document

    /// The on-disk shape. Separate from the value type above so the
    /// wire form is written out in one readable place rather than
    /// assembled by `CodingKeys` scattered across a model.
    struct Document: Encodable {
        let readme: [String]
        let group: Group
        let member: Member
        let rules: Rules?

        struct Group: Encodable {
            let id: String
            let name: String
        }

        struct Member: Encodable {
            let alias: String
            let blsPublicKey: String
            let sendingPublicKey: String?
            let signature: String?
            let signed: Bool
            /// Present only when `signed` is false: why there is
            /// nothing to check, in words rather than a code.
            let note: String?

            /// snake_case, like every other key in the file — and, more
            /// to the point, like the names `_readme` tells the reader
            /// to look for. Instructions that cite a key the document
            /// doesn't contain are worse than no instructions.
            enum CodingKeys: String, CodingKey {
                case alias
                case blsPublicKey = "bls_public_key"
                case sendingPublicKey = "sending_public_key"
                case signature
                case signed
                case note
            }
        }

        struct Rules: Encodable {
            let text: String
            let sha256: String
            let matchesCurrentRules: Bool
            let currentText: String?

            enum CodingKeys: String, CodingKey {
                case text
                case sha256
                case matchesCurrentRules = "matches_current_rules"
                case currentText = "current_text"
            }
        }

        enum CodingKeys: String, CodingKey {
            case readme = "_readme"
            case group
            case member
            case rules
        }
    }

    var document: Document {
        Document(
            readme: Self.readme,
            group: .init(id: groupIDHex, name: groupName),
            member: .init(
                alias: memberAlias,
                blsPublicKey: memberBlsHex,
                sendingPublicKey: sendingPublicKey.map(\.hexString),
                signature: signature.map(\.hexString),
                signed: standing.isProven,
                note: Self.note(for: standing)
            ),
            rules: rules.map { text in
                // From the standing, not re-derived. `signed` and
                // `signedEarlierVersion` already *are* this fact, and a
                // type whose thesis is single-sourced derivation should
                // not answer the same question twice.
                let matches = standing != .signedEarlierVersion
                return .init(
                    text: text,
                    sha256: GroupRules.hash(text).hexString,
                    matchesCurrentRules: matches,
                    // Only where it differs, and then in full: a reader
                    // told the wording diverged has nothing to compare
                    // against otherwise. Identical copies would just be
                    // the same paragraph twice.
                    currentText: matches ? nil : currentRules
                )
            }
        )
    }

    /// How to check this without trusting the app that wrote it. Split
    /// across lines because JSON has no comments and a single 400-column
    /// string is not something anyone reads.
    static let readme = [
        "Proof that this member agreed to this group's rules.",
        "To verify, with any Ed25519 implementation:",
        "  1. message = \"onym-group-rules-v1\" (ASCII, 19 bytes)",
        "             || group.id (32 bytes, hex above)",
        "             || SHA-256(rules.text as UTF-8) (32 bytes)",
        "             || member.sending_public_key (32 bytes, hex above)",
        "  2. check member.signature against that message and that key.",
        "The rules text here is the wording this member signed. When",
        "matches_current_rules is false, the group has changed its rules",
        "since — the signature still covers the text in this file, and",
        "current_text carries what the group says now, to compare.",
        "",
        "What the signature does NOT cover, and what you must not read",
        "out of it: alias and bls_public_key. Neither is inside the",
        "signed message. The alias is a name this member chose and can",
        "change, and the pairing of that name and that BLS key with this",
        "signature is an assertion by the app that wrote this file — not",
        "something the signature proves. What the signature proves is",
        "that the holder of sending_public_key agreed to these rules for",
        "this group. Tie that key to a person by some other means.",
    ]

    static func note(for standing: GroupRulesStanding) -> String? {
        switch standing {
        case .signed, .signedEarlierVersion:
            nil
        case .noRules:
            "This group has no rules, so nothing was asked of anyone."
        case .notCollected:
            "This kind of group has no join approval, so no agreement to its rules is "
            + "collected from anyone."
        case .author:
            "This member wrote the rules; founders do not sign their own."
        case .didNotSign:
            "Joined before this group had rules, or from an app version that predates them."
        case .unknownRules:
            "A signature is stored for this member, but the wording it covers is not on "
            + "this device, so nothing here can check it."
        case .doesNotVerify:
            "A signature was stored for this member and it does not verify."
        }
    }

}
