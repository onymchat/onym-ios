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

    // `clamped(_:signerCount:)` and `isUsable(_:signerCount:)` lived
    // here and counted people. `TreasuryQuorum.isReachable` counts
    // weight, which is what the ledger enforces, and the two disagreed
    // the moment anybody was worth more than one signature.
    //
    // They are gone rather than deprecated. Leaving a headcount twin in
    // the file is exactly how the creation path got converted and the
    // steppers did not — a second shape of the same job is something
    // the next caller can pick by accident.
}
