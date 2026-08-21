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
    /// The longest rules text an invite may carry.
    ///
    /// The binding constraint is the QR code, not the screen. An invite
    /// link is `base64(JSON)` in a URL, rendered at correction level M
    /// (`SettingsQRCode`), whose byte-mode ceiling is 2331 bytes.
    /// Measured end to end, with both 32-byte keys and a 30-character
    /// group name in the JSON:
    ///
    ///     500 ASCII characters     →   924-byte link
    ///     500 Cyrillic characters  →  1591-byte link
    ///     500 CJK characters       →  2258-byte link
    ///
    /// So 500 fits even when every character costs three UTF-8 bytes,
    /// which is the case that decides the cap. A longer one would
    /// produce links that encode fine and then fail to scan — the worst
    /// way to find out.
    ///
    /// The headroom in that last row is thin, and it is shared with the
    /// group name, which has no cap of its own: a 300-character name
    /// alongside 500 characters of CJK rules would push the link past
    /// the ceiling. The failure is soft — `CIQRCodeGenerator` returns
    /// no image and the link stays copyable — but it is why this
    /// number should not be raised without re-measuring the pair.
    public static let maxLength = 500

    /// Domain separator. Versioned: a change to the statement's shape
    /// must not let old signatures verify under the new reading.
    static let domain = "onym-group-rules-v1"

    /// The one canonical form, applied by *both* sides before hashing.
    ///
    /// Ends-only trimming, nothing else: the founder wrote this text
    /// and a joiner is agreeing to it, so collapsing inner whitespace
    /// or normalising case would mean signing something other than what
    /// was displayed. Trailing newlines from a text field are the one
    /// difference that carries no meaning, and letting them through
    /// would make agreement fail on an invisible character.
    public static func canonical(_ rules: String) -> String {
        rules.trimmingCharacters(in: .whitespacesAndNewlines)
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
    public static func statement(
        groupID: Data,
        rulesHash: Data,
        joinerSendingPublicKey: Data
    ) -> Data {
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
