import Foundation
import CryptoKit

/// The rules a founder sets for a group, and the joiner's signed
/// agreement to them.
///
/// ## Why a signature at all
///
/// A founder admitting a stranger is deciding on two things: who is
/// asking, and what they have agreed to. The first was already
/// provable — the request carries the joiner's long-term keys. The
/// second was not, and could not be inferred from the envelope: the
/// sealed envelope's Ed25519 signature covers the *ephemeral public
/// key* only (`IdentityRepository.sealInvitation`), not the payload
/// under it. A founder holding such an envelope can produce a
/// different plaintext for the same signature, so it proves nothing to
/// a third party about what the joiner said.
///
/// So agreement gets its own detached signature, over bytes that name
/// what is being agreed to and by whom.
///
/// ## The statement
///
///     "onym-group-rules-v1" ‖ group_id (32) ‖ SHA256(rules) (32)
///                           ‖ joiner_sending_pub (32)
///
/// Every component after the domain string is fixed-length, so the
/// concatenation is unambiguous without length prefixes.
///
///  - The **domain string** keeps this signature from being replayable
///    as any other signature this identity produces — the same Ed25519
///    key signs moderation mandates and report disclosures.
///  - **`group_id`** binds the agreement to one group. Without it, an
///    acceptance collected for a permissive group could be shown as
///    agreement to a stricter group's rules that happen to be equal.
///  - **`SHA256(rules)`** is what makes it an agreement to *these*
///    rules rather than to the idea of rules. Changing a comma
///    invalidates it.
///  - **`joiner_sending_pub`** names the signer inside the signed
///    bytes, so a signature lifted from one request cannot be
///    re-attributed to another joiner.
///
/// Deliberately **not** signed: a timestamp. A joiner-supplied one is
/// unverifiable, and the only trustworthy time is when the founder's
/// device received the request — which the founder records itself.
///
/// ## Keeping the proof
///
/// A signature is only evidence if the bytes it covers can be produced
/// again. The verifier therefore stores the exact rules text alongside
/// the signature; a stored hash with no text proves that *something*
/// was agreed to and never what. This is the same discipline the
/// moderation layer follows for mandates, where the signed manifest
/// bytes are retained rather than re-derived.
public enum GroupRules {
    /// The most rules an invite may carry, in **UTF-8 bytes**.
    ///
    /// Bytes, not characters, for two reasons that both bite.
    ///
    /// A character cap doesn't bound the payload it exists to bound. A
    /// ZWJ emoji cluster (👨‍👩‍👧‍👦) is one `Character` and 25 UTF-8
    /// bytes, so 500 of them is a legal 500-"character" rules text and
    /// a ~12.5 KB payload — seven times the ceiling below.
    ///
    /// And a character cap isn't the same cap on both platforms.
    /// Swift's `String.count` counts grapheme clusters; Kotlin's
    /// `String.length` counts UTF-16 units. One non-BMP character makes
    /// them disagree, and because decode *rejects* an over-long value
    /// rather than truncating it, disagreement is an unusable link
    /// rather than a cosmetic difference. UTF-8 byte count is the only
    /// unit the two compute identically.
    ///
    /// The value: a QR code at correction level M (`SettingsQRCode`)
    /// holds 2331 bytes, and the link is `base64(JSON)`, so the rules
    /// get ~1500 bytes of it. Measured end to end, with both 32-byte
    /// keys and a 30-character Latin group name:
    ///
    ///     1500 bytes as 1500 ASCII characters  →  2273-byte link
    ///     1500 bytes as  750 Cyrillic chars    →  2273-byte link
    ///     1500 bytes as  500 CJK characters    →  2273-byte link
    ///
    /// — the same link length, which is the point of measuring the
    /// budget in the unit the wire actually spends.
    ///
    /// The remaining headroom is shared with the group name, which has
    /// no cap of its own: 1500 bytes of rules alongside a 30-character
    /// CJK name overruns. The failure is soft — `CIQRCodeGenerator`
    /// returns no image and the link stays copyable — but it is why
    /// this number should not be raised without re-measuring the pair.
    /// `GroupRulesWireTests` pins both sides of that boundary.
    public static let maxBytes = 1500

    /// What the compose field counts down from, in characters. A
    /// guide for the person typing, not the limit that decides whether
    /// a link is valid — `maxBytes` is. Latin text hits neither before
    /// the other; scripts that cost more per character hit the byte
    /// cap first, which is correct and is why the field checks both.
    public static let maxLength = 500

    /// Domain separator. Versioned: a change to the statement's shape
    /// must not let old signatures verify under the new reading.
    static let domain = "onym-group-rules-v1"

    /// Exactly the codepoints `canonical` trims from the ends, pinned
    /// rather than named.
    ///
    /// `Foundation.whitespacesAndNewlines` and Kotlin's `String.trim()`
    /// are not the same set: `Character.isWhitespace` excludes NBSP
    /// (U+00A0) and the narrow/figure spaces, which Foundation trims.
    /// Text pasted from a web page routinely carries a leading or
    /// trailing NBSP, so the difference is not theoretical — one
    /// platform would hash the NBSP and the other wouldn't, a genuine
    /// agreement would fail to verify, and the founder would read that
    /// as a signature that doesn't check out rather than as a
    /// whitespace disagreement.
    ///
    /// So the set is written out, and Android must write out the same
    /// one. These are the codepoints of
    /// `CharacterSet.whitespacesAndNewlines` as of this writing;
    /// spelling them here also stops a Foundation revision from
    /// silently changing what a signature covers.
    public static let trimmedCodepoints = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{0085}\u{00A0}"
        + "\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}"
        + "\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}"
        + "\u{3000}"
    )

    /// The one canonical form, applied by *both* sides before hashing.
    ///
    /// Ends-only trimming, nothing else: the founder wrote this text
    /// and a joiner is agreeing to it, so collapsing inner whitespace
    /// or normalising case would mean signing something other than what
    /// was displayed. Trailing newlines from a text field are the one
    /// difference that carries no meaning, and letting them through
    /// would make agreement fail on an invisible character.
    ///
    /// See `trimmedCodepoints` for why the set is spelled out.
    public static func canonical(_ rules: String) -> String {
        rules.trimmingCharacters(in: trimmedCodepoints)
    }

    /// Whether this text fits an invite, in the unit the wire spends.
    public static func fits(_ rules: String) -> Bool {
        canonical(rules).utf8.count <= maxBytes
    }

    /// `nil` for rules that are absent or blank — a group with no rules
    /// asks for no agreement, and an empty string must not become a
    /// thing to sign.
    public static func normalized(_ rules: String?) -> String? {
        guard let rules else { return nil }
        let canonical = canonical(rules)
        return canonical.isEmpty ? nil : canonical
    }

    /// SHA-256 over the canonical text's UTF-8. The identity of a set
    /// of rules, and what the founder compares against.
    public static func hash(_ rules: String) -> Data {
        Data(SHA256.hash(data: Data(canonical(rules).utf8)))
    }

    /// The exact bytes both sides sign and verify. See the type doc.
    ///
    /// The preconditions are the unambiguity argument, enforced: the
    /// concatenation needs no length prefixes *because* all three
    /// components are fixed-length, and a caller that passed a short
    /// group id would silently produce a preimage some other triple
    /// could also produce. Every caller already holds validated
    /// values, so this fires only on a programming error.
    public static func statement(
        groupID: Data,
        rulesHash: Data,
        joinerSendingPublicKey: Data
    ) -> Data {
        precondition(groupID.count == 32, "groupID must be 32 bytes")
        precondition(rulesHash.count == 32, "rulesHash must be 32 bytes")
        precondition(
            joinerSendingPublicKey.count == 32,
            "joinerSendingPublicKey must be 32 bytes"
        )
        var bytes = Data(domain.utf8)
        bytes.append(groupID)
        bytes.append(rulesHash)
        bytes.append(joinerSendingPublicKey)
        return bytes
    }

    /// Whether `signature` is this joiner agreeing to exactly `rules`
    /// for exactly this group.
    ///
    /// Takes the rules *text* rather than a hash on purpose: the caller
    /// that can't produce the text has nothing to verify against, and
    /// making that impossible to express is cheaper than documenting
    /// it.
    public static func isAgreement(
        signature: Data,
        rules: String,
        groupID: Data,
        joinerSendingPublicKey: Data
    ) -> Bool {
        // Sizes checked before `statement`, whose preconditions are for
        // programming errors: everything here arrives from a stranger,
        // and wrong-sized bytes are a "no" rather than a crash.
        guard groupID.count == 32, joinerSendingPublicKey.count == 32 else { return false }
        guard let key = try? Curve25519.Signing.PublicKey(
            rawRepresentation: joinerSendingPublicKey
        ) else { return false }
        let statement = statement(
            groupID: groupID,
            rulesHash: hash(rules),
            joinerSendingPublicKey: joinerSendingPublicKey
        )
        return key.isValidSignature(signature, for: statement)
    }
}
