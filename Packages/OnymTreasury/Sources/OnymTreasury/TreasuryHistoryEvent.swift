import Foundation
import OnymStellar

/// One thing that happened to a treasury, as a sentence.
///
/// The screen this replaces listed five transaction hashes and a tick.
/// A hash is the receipt, not the event — it is what someone checks
/// when they do not trust this app, which is a real need and a
/// different one from "what happened to our money".
///
/// Every field here is decoded from the envelope the ledger returned.
/// Nothing a proposer typed reaches it, and neither does anything this
/// app stored: a history built from local records would describe what
/// this device believed rather than what the network did, and the two
/// differ exactly when it matters.
public struct TreasuryHistoryEvent: Equatable, Sendable, Identifiable {
    /// What the transaction did, in the terms the redesign's vocabulary
    /// table settled on — plain meaning first, Stellar's word only
    /// where it is the thing being named.
    public enum Kind: Equatable, Sendable {
        /// Someone sent assets in. The treasury is the destination.
        case received(amount: StellarAmount, asset: StellarAsset, from: StellarAccountID)
        /// The treasury paid someone.
        case sent(amount: StellarAmount, asset: StellarAsset, to: StellarAccountID)
        /// "The treasury started holding USDC" — a trustline, named by
        /// what it does rather than by what Stellar calls it.
        case startedHolding(StellarAsset)
        case stoppedHolding(StellarAsset)
        /// The transaction that made it a treasury.
        case created
        /// Signers or thresholds changed.
        case changedControl
        /// Decoded, but not something this build names.
        case other
    }

    public let hash: String
    public let at: Date
    public let successful: Bool
    public let kind: Kind
    /// The account that paid for and sourced the transaction — which is
    /// how a funding payment gets attributed to the person who made it.
    public let sourceAccount: StellarAccountID

    public var id: String { hash }

    /// Read one ledger row.
    ///
    /// `treasury` decides direction: the same payment operation is
    /// "received" or "sent" depending on which side of it this account
    /// is, and a screen that got that backwards would be worse than a
    /// hash.
    public init(_ transaction: HorizonTransaction, treasury: StellarAccountID) {
        self.hash = transaction.hash
        self.at = transaction.ledgerCloseTime
        self.successful = transaction.successful
        self.sourceAccount = transaction.sourceAccount

        guard let envelope = try? TransactionEnvelope(base64XDR: transaction.envelopeXDR) else {
            // The hash and the outcome are still true, and they are
            // what the detail screen needs. Inventing a description
            // from an envelope that would not decode is the one thing
            // this type must not do.
            self.kind = .other
            return
        }
        let operations = envelope.transaction.operations
        // The first operation this build can name. A treasury
        // transaction carries one meaningful operation in every shape
        // this app builds; a `setOptions` run is the exception and it
        // is all one change.
        var kind = Kind.other
        for operation in operations {
            switch operation.body {
            case .createAccount(let destination, _) where destination == treasury:
                kind = .created
            case .payment(let destination, let asset, let amount):
                kind = destination == treasury
                    ? .received(amount: amount, asset: asset, from: transaction.sourceAccount)
                    : .sent(amount: amount, asset: asset, to: destination)
            case .changeTrust(let asset, let limit):
                kind = limit.stroops == 0 ? .stoppedHolding(asset) : .startedHolding(asset)
            case .setOptions:
                // Creation is `createAccount` plus a run of these, and
                // the earlier branch has already claimed it.
                if case .other = kind { kind = .changedControl }
            case .createAccount:
                break
            }
            if case .other = kind { continue } else { break }
        }
        self.kind = kind
    }
}
