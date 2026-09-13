import Foundation
import OnymStellar

/// Turning "who the founder ticked" into a signer set and thresholds
/// the account can actually satisfy.
///
/// Pure, and deliberately not left in the flow. Each rule here
/// corresponds to a way a founder could otherwise create an account
/// that is broken the moment it exists — and unlike most mistakes, none
/// of them can be undone afterwards, because undoing them needs the
/// quorum that no longer exists.
public enum TreasurySignerSelection {

    /// What a spendable-amount field means, including the half-typed
    /// states a text field legitimately passes through.
    ///
    /// `StellarAmount(decimalString:)` refuses "" and "1.", which are
    /// both on the way to a real number — so a field being cleared made
    /// the funding breakdown vanish mid-keystroke, and an empty field
    /// failed creation with "That isn't an amount" when "nothing
    /// spendable" is an ordinary thing to want.
    ///
    /// Here rather than on the flow so it can be tested without a
    /// simulator's worth of collaborators. The first version of that
    /// test re-declared this logic locally and therefore passed
    /// regardless of what the flow did.
    public static func spendableAmount(_ field: String) -> StellarAmount? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." { return StellarAmount(stroops: 0) }
        if trimmed.hasSuffix(".") {
            return try? StellarAmount(decimalString: String(trimmed.dropLast()))
        }
        return try? StellarAmount(decimalString: trimmed)
    }

    /// The accounts a signer set will actually contain, from the
    /// members ticked on screen.
    ///
    /// Two things happen here that the tick list does not do on its
    /// own. Members whose declaration has stopped verifying — or who
    /// have left the group — drop out, because the transaction is built
    /// from the resolvable ones and a threshold counted from the raw
    /// ticks would then exceed the weight that exists. And duplicate
    /// accounts collapse: two people naming the same address (a shared
    /// wallet, a key pasted twice) contribute one signer of weight one,
    /// not two, so counting heads would again set a threshold nobody
    /// can reach.
    public static func accounts(
        ticked: Set<String>,
        from candidates: [(blsPubkeyHex: String, account: StellarAccountID, nominatable: Bool)]
    ) -> [StellarAccountID] {
        var seen = Set<String>()
        var resolved: [StellarAccountID] = []
        for candidate in candidates
        where candidate.nominatable && ticked.contains(candidate.blsPubkeyHex) {
            guard seen.insert(candidate.account.accountID).inserted else { continue }
            resolved.append(candidate.account)
        }
        return resolved
    }

    /// Thresholds that the given signer set can satisfy, and that do not
    /// let a minority seize the majority's account.
    ///
    /// Two clamps, both load-bearing:
    ///
    /// - **Neither may exceed the total weight.** A threshold above what
    ///   the signers add up to is an account no quorum can ever act on,
    ///   permanently — including to fix the threshold.
    /// - **`high` may not be below `medium`.** The steppers are
    ///   independent on screen, so "3 of 3 to spend, 1 of 3 to change
    ///   who can spend" is two taps away — and it means any single
    ///   co-signer can `setOptions` themselves to sole control and then
    ///   spend everything alone. Raising `high` to meet `medium` is the
    ///   safe direction: it is the setting that governs who is allowed
    ///   to change the other.
    public static func clamped(
        _ thresholds: TreasuryThresholds,
        signerCount: Int
    ) -> TreasuryThresholds {
        let total = UInt32(max(signerCount, 1))
        let medium = min(max(thresholds.medium, 1), total)
        let high = min(max(thresholds.high, medium), total)
        return TreasuryThresholds(
            low: min(max(thresholds.low, 1), total),
            medium: medium,
            high: high
        )
    }

    /// Whether a set of thresholds would leave the treasury able to act
    /// at all. `accounts(ticked:from:)` can return fewer signers than
    /// were ticked, so this is asked of the resolved list.
    public static func isUsable(
        _ thresholds: TreasuryThresholds,
        signerCount: Int
    ) -> Bool {
        signerCount > 0
            && thresholds.medium <= UInt32(signerCount)
            && thresholds.high <= UInt32(signerCount)
            && thresholds.high >= thresholds.medium
    }
}
