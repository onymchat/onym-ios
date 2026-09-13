import CryptoKit
import Foundation
import OnymStellar

/// A member telling their group which Stellar account should be their
/// co-signer on the treasury.
///
/// ## Why this is a signed statement
///
/// The same reason `GroupRules` needed one. A sealed envelope's
/// Ed25519 signature covers the *ephemeral public key*, not the payload
/// under it, so a member holding an envelope can produce a different
/// plaintext for the same signature. "Alice nominated this account"
/// therefore needs its own detached signature over bytes that name what
/// is being declared and by whom.
///
/// ## The statement
///
///     "onym-treasury-signer-v1" ‖ group_id (32) ‖ signer_account (32)
///                               ‖ declarer_sending_pub (32)
///
/// Every component after the domain string is fixed-length, so the
/// concatenation is unambiguous without length prefixes.
///
///  - The **domain string** keeps this from being replayable as any
///    other signature this identity produces — the same key signs
///    moderation mandates and rules agreements.
///  - **`group_id`** binds the declaration to one treasury. Without it,
///    an account declared to a group of friends could be replayed into
///    a group holding real money.
///  - **`signer_account`** is what is actually being claimed.
///  - **`declarer_sending_pub`** names the declarer inside the signed
///    bytes, so a declaration cannot be re-attributed to another member.
///
/// ## What this does and does not prove
///
/// It proves **which member declared which account**. It does not prove
/// they control that account — an Onym identity key cannot speak for a
/// Stellar account it does not hold. For an Onym-derived signer the two
/// coincide, because the declared account *is* a key this device can
/// sign with. For an external account, control is only demonstrated
/// when that account first co-signs something, and
/// `TreasurySignerStanding` reports the difference rather than letting
/// the UI imply a check that never ran.
///
/// Declaring an account you do not control is not a way to take
/// anyone's money — it costs you your own seat at the table, because
/// the signature the treasury waits for will never arrive. It is a way
/// to *deadlock* a treasury, which is why the founder sees the
/// unproven state before creating one.
public enum TreasurySignerDeclaration {
    static let domain = "onym-treasury-signer-v1"

    /// The exact bytes a declaration signature covers.
    public static func statement(
        groupID: Data,
        signerAccount: StellarAccountID,
        declarerSendingPublicKey: Data
    ) -> Data {
        var bytes = Data(domain.utf8)
        bytes.append(groupID)
        bytes.append(signerAccount.publicKey)
        bytes.append(declarerSendingPublicKey)
        return bytes
    }

    /// Whether `signature` is a genuine declaration of `signerAccount`
    /// by the holder of `declarerSendingPublicKey`.
    ///
    /// Wrong-sized inputs return `false` rather than throwing: this is
    /// asked of values that arrived over the wire, and "these bytes do
    /// not show agreement" is the same answer for a malformed signature
    /// as for a wrong one.
    public static func isDeclaration(
        signature: Data,
        signerAccount: StellarAccountID,
        groupID: Data,
        declarerSendingPublicKey: Data
    ) -> Bool {
        guard signature.count == 64, declarerSendingPublicKey.count == 32 else {
            return false
        }
        guard let key = try? Curve25519.Signing.PublicKey(
            rawRepresentation: declarerSendingPublicKey
        ) else { return false }
        return key.isValidSignature(
            signature,
            for: statement(
                groupID: groupID,
                signerAccount: signerAccount,
                declarerSendingPublicKey: declarerSendingPublicKey
            )
        )
    }
}

/// Where a declared account came from. Persisted and on the wire, so
/// the raw values are stable.
public enum TreasurySignerSource: String, Codable, Equatable, Sendable {
    /// The identity's own derived treasury key. This device can sign
    /// with it, so co-signing is one tap.
    case onym
    /// An account the member keeps elsewhere. Signing leaves the app
    /// through a SEP-0007 handoff to their wallet.
    case external
}

/// What this device can say about one member's declared signer.
///
/// Derived every time it is asked, never stored as a flag — same
/// discipline as `GroupRulesStanding`. A stored boolean would be a
/// claim about a check somebody once ran.
public enum TreasurySignerStanding: Equatable, Sendable {
    /// No account declared. They cannot be made a co-signer yet.
    case notDeclared
    /// Declared, signature verified, and the key is one this device
    /// derives — so control is not in question.
    case declaredOnym
    /// Declared and the signature verifies, but the account is held
    /// outside Onym. Nothing has yet demonstrated that the declarer can
    /// sign with it.
    case declaredExternalUnproven
    /// Declared externally, and that account has since produced a valid
    /// signature over one of this treasury's transactions. Control is
    /// no longer an assumption.
    case declaredExternalProven
    /// A declaration whose signature does not verify against the
    /// declarer's key. Kept distinct from `notDeclared` because the two
    /// say different things, and only one of them is odd.
    case doesNotVerify

    /// Whether a founder may safely add this member to a signer set.
    ///
    /// `declaredExternalUnproven` is included: refusing it would make
    /// the feature unusable for exactly the people it was built for,
    /// who by definition have not signed anything yet. The risk it
    /// carries is deadlock, not theft, and the creation screen names it
    /// rather than this type silently deciding.
    public var canBeNominated: Bool {
        switch self {
        case .declaredOnym, .declaredExternalUnproven, .declaredExternalProven: true
        case .notDeclared, .doesNotVerify: false
        }
    }
}
