import Foundation
import OnymStellar

/// What a proposal does, in a form a screen can render.
///
/// ## Why this type exists at all
///
/// Because there must be exactly one place that turns operations into
/// words. The proposal card in the chat thread and the treasury screen
/// show the same transaction; if each assembled its own sentence, a
/// re-wording would silently make them disagree, and a person could
/// approve one description having read the other.
///
/// It is the same discipline `ChatSystemEvent.localizedText` follows,
/// with more at stake.
///
/// ## Structured, never prose
///
/// Each line is a label and a value the caller renders — not a
/// pre-formatted sentence. Amounts stay `StellarAmount` and accounts
/// stay `StellarAccountID` as far as possible so the UI can give a
/// recipient address a monospaced font and full selectable text rather
/// than burying it mid-sentence, where nobody checks it.
///
/// ## It is built from the decoded transaction
///
/// Every value here comes from `proposal.envelope.transaction`, which
/// this device decoded itself. Nothing the proposer wrote reaches a
/// screen. That is the whole reason `OnymStellar` ships a parser.
public struct TreasuryProposalDescription: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public enum Value: Equatable, Sendable {
            case text(String)
            /// Rendered monospaced and fully selectable — an address is
            /// checked character by character or not at all.
            case account(StellarAccountID)
            case amount(StellarAmount, code: String)
        }

        public let label: String
        public let value: Value
        /// Lines a person should look hardest at: the recipient, the
        /// amount, the key being handed authority. The UI leans on this
        /// rather than deciding for itself which rows matter.
        public let isPrincipal: Bool

        public var id: String { label }

        public init(label: String, value: Value, isPrincipal: Bool = false) {
            self.label = label
            self.value = value
            self.isPrincipal = isPrincipal
        }
    }

    /// Short headline, e.g. "Pay 25 USDC".
    public let title: String
    public let lines: [Line]
    /// Set when the transaction does something this description could
    /// not fully account for.
    ///
    /// Never nil-and-fine by default: if a proposal carries more
    /// operations than the summary explains, the card says so instead
    /// of showing a tidy summary of part of it. A partial description
    /// that looks complete is the failure this whole design is built to
    /// avoid.
    public let caveat: String?

    public init(title: String, lines: [Line], caveat: String? = nil) {
        self.title = title
        self.lines = lines
        self.caveat = caveat
    }

    /// Describe a proposal from the transaction this device decoded.
    public init(_ proposal: TreasuryProposal) {
        let operations = proposal.operations
        let transactionFee = proposal.envelope.transaction.fee
        var lines: [Line] = []
        var title = "Treasury transaction"
        var caveat: String?

        switch operations.first?.body {
        case .payment(let destination, let asset, let amount):
            title = "Pay \(amount.decimalString) \(asset.code)"
            lines.append(Line(
                label: "Amount",
                value: .amount(amount, code: asset.code),
                isPrincipal: true
            ))
            lines.append(Line(label: "To", value: .account(destination), isPrincipal: true))
            if let issuer = asset.issuer {
                // The issuer is part of the asset's identity, not a
                // detail. Two different issuers can both call their
                // token USDC, and only one of them is the real one.
                lines.append(Line(label: "\(asset.code) issued by", value: .account(issuer)))
            }

        case .changeTrust(let asset, let limit):
            let closing = limit.stroops == 0
            title = closing ? "Stop holding \(asset.code)" : "Hold \(asset.code)"
            lines.append(Line(label: "Asset", value: .text(asset.code), isPrincipal: true))
            if let issuer = asset.issuer {
                lines.append(Line(label: "Issued by", value: .account(issuer), isPrincipal: true))
            }
            if !closing {
                lines.append(Line(
                    label: "Limit",
                    value: limit == .max
                        ? .text("No limit")
                        : .amount(limit, code: asset.code)
                ))
                lines.append(Line(
                    label: "Reserve",
                    value: .text("Locks one more base reserve in the treasury")
                ))
            }

        case .setOptions:
            (title, lines) = Self.describeControl(operations)

        case .createAccount, .none:
            // Creation is never proposed to a group — the treasury does
            // not exist yet, so there is no signer set to ask. Reaching
            // here means something arrived that the verifier should have
            // refused, and the honest rendering is to say nothing about
            // what it does.
            caveat = "This transaction isn't one this app knows how to describe. Don't sign it."
        }

        // The fee is a spend, and it is in none of the operation rows
        // above. Shown only when it is above the ordinary rate, because
        // a line reading "0.00001 XLM" on every card teaches people to
        // skip it, and the one time it matters is the time it is large.
        // `TreasuryProposalVerifier` refuses anything truly
        // extravagant; this is what makes the rest visible.
        let ordinaryFee = 100 * Int64(max(operations.count, 1))
        if Int64(transactionFee) > ordinaryFee {
            lines.append(Line(
                label: "Network fee",
                value: .amount(StellarAmount(stroops: Int64(transactionFee)), code: "XLM"),
                isPrincipal: Int64(transactionFee) > ordinaryFee * 10
            ))
        }

        // The count check is the backstop. Every branch above reads only
        // the operations it expects, so anything extra would otherwise
        // be invisible — and an unexplained operation in a transaction
        // someone is about to sign is exactly the thing worth shouting
        // about.
        let explained = Self.explainedOperationCount(operations)
        if caveat == nil, operations.count > explained {
            caveat = "This transaction does \(operations.count - explained) more thing(s) this summary doesn't show. Don't sign it unless you know what they are."
        }

        self.title = title
        self.lines = lines
        self.caveat = caveat
    }

    private static func explainedOperationCount(_ operations: [StellarOperation]) -> Int {
        switch operations.first?.body {
        case .setOptions:
            // The control branch reads the whole run.
            return operations.prefix { if case .setOptions = $0.body { return true }
                                       return false }.count
        case .payment, .changeTrust:
            return 1
        case .createAccount, .none:
            return 0
        }
    }

    /// Signer and threshold changes, which are the proposals worth
    /// reading most carefully — they decide who can spend everything
    /// else.
    private static func describeControl(
        _ operations: [StellarOperation]
    ) -> (String, [Line]) {
        var lines: [Line] = []
        var added: [StellarAccountID] = []
        var removed: [StellarAccountID] = []
        var thresholds: (low: UInt32?, medium: UInt32?, high: UInt32?) = (nil, nil, nil)
        var masterWeight: UInt32?

        for operation in operations {
            guard case .setOptions(let fields) = operation.body else { continue }
            if let signer = fields.signer {
                if signer.weight > 0 { added.append(signer.key) } else { removed.append(signer.key) }
            }
            thresholds.low = fields.lowThreshold ?? thresholds.low
            thresholds.medium = fields.mediumThreshold ?? thresholds.medium
            thresholds.high = fields.highThreshold ?? thresholds.high
            masterWeight = fields.masterWeight ?? masterWeight
        }

        for account in added {
            lines.append(Line(label: "Add co-signer", value: .account(account), isPrincipal: true))
        }
        for account in removed {
            lines.append(Line(
                label: "Remove co-signer",
                value: .account(account),
                isPrincipal: true
            ))
        }
        if let medium = thresholds.medium {
            lines.append(Line(
                label: "Signatures to spend",
                value: .text(String(medium)),
                isPrincipal: true
            ))
        }
        if let high = thresholds.high {
            lines.append(Line(
                label: "Signatures to change control",
                value: .text(String(high)),
                isPrincipal: true
            ))
        }
        if let low = thresholds.low {
            lines.append(Line(label: "Signatures for minor changes", value: .text(String(low))))
        }
        if let masterWeight {
            // Only ever seen on a creation envelope in practice. If it
            // shows up in a proposal it is someone re-enabling the
            // account's own key — that is, undoing the thing that makes
            // the treasury shared — and it is spelled out.
            lines.append(Line(
                label: "Treasury's own key",
                value: .text(masterWeight == 0
                    ? "Stays switched off"
                    : "SWITCHED BACK ON \u{2014} weight \(masterWeight)"),
                isPrincipal: masterWeight != 0
            ))
        }

        let title: String
        if !added.isEmpty, removed.isEmpty {
            title = added.count == 1 ? "Add a co-signer" : "Add \(added.count) co-signers"
        } else if added.isEmpty, !removed.isEmpty {
            title = removed.count == 1 ? "Remove a co-signer" : "Remove \(removed.count) co-signers"
        } else if added.isEmpty, removed.isEmpty {
            title = "Change how many signatures are needed"
        } else {
            title = "Change who controls the treasury"
        }
        return (title, lines)
    }
}
