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
            /// Runtime data — a memo someone typed, a home domain, a
            /// hex flag word. Rendered verbatim, never looked up.
            case text(String)
            /// UI copy. A separate case from `text` because the two are
            /// different things that happen to both be words: one is a
            /// stranger's bytes and must never be looked up as a key,
            /// the other is a sentence this app wrote and must be.
            case copy(LocalizedStringResource)
            /// Rendered monospaced and fully selectable — an address is
            /// checked character by character or not at all.
            case account(StellarAccountID)
            case amount(StellarAmount, code: String)
        }

        /// A key, not a `String`. `Text(_: String)` is the
        /// non-localizing overload, so every label on this card — the
        /// recipient, the amount, the authority being handed over —
        /// rendered English in every language.
        public let label: LocalizedStringResource
        public let value: Value
        /// Lines a person should look hardest at: the recipient, the
        /// amount, the key being handed authority. The UI leans on this
        /// rather than deciding for itself which rows matter.
        public let isPrincipal: Bool

        /// Derived, not random.
        ///
        /// `describeControl` emits one line per account, all labelled
        /// "Add co-signer" — so a label-keyed `id` collided in
        /// `ForEach` and a proposal adding two co-signers rendered
        /// *one* address. The operation-count backstop cannot catch it:
        /// the `setOptions` run is fully explained, so no caveat fires.
        /// A summary of part of a control change, which is precisely
        /// what this type exists to prevent.
        /// `label` alone collided: `describeControl` emits one line per
        /// account, all labelled "Add co-signer", so a proposal adding
        /// two rendered a single address.
        ///
        /// A fresh `UUID` fixed that and broke something quieter — it
        /// made `Line`, and so the whole description, never equal to an
        /// identically-derived value despite conforming to `Equatable`.
        /// Rows are rebuilt on every snapshot, so `ForEach` re-identified
        /// every line and tore down the address `Text`, dropping any
        /// in-progress selection on the recipient: the one field the
        /// card asks people to check character by character.
        /// Includes `ordinal` because label and value are not enough:
        /// two identical rows — the same amount to the same account
        /// twice, which is a transaction someone might well propose —
        /// collided in `ForEach` and rendered as one.
        public var id: String { "\(ordinal)|\(label.key)|\(value)" }

        /// Position in the description. Assigned when the lines are
        /// finalised, so nothing constructing a `Line` has to count.
        public internal(set) var ordinal: Int = 0

        public init(
            label: LocalizedStringResource,
            value: Value,
            isPrincipal: Bool = false
        ) {
            self.label = label
            self.value = value
            self.isPrincipal = isPrincipal
        }
    }

    /// Short headline, e.g. "Pay 25 USDC".
    public let title: LocalizedStringResource
    public let lines: [Line]
    /// Set when the transaction does something this description could
    /// not fully account for.
    ///
    /// Never nil-and-fine by default: if a proposal carries more
    /// operations than the summary explains, the card says so instead
    /// of showing a tidy summary of part of it. A partial description
    /// that looks complete is the failure this whole design is built to
    /// avoid.
    public let caveat: LocalizedStringResource?

    public init(
        title: LocalizedStringResource,
        lines: [Line],
        caveat: LocalizedStringResource? = nil
    ) {
        self.title = title
        self.lines = lines.enumerated().map { index, line in
            var numbered = line
            numbered.ordinal = index
            return numbered
        }
        self.caveat = caveat
    }

    /// Describe a proposal from the transaction this device decoded.
    public init(_ proposal: TreasuryProposal) {
        let operations = proposal.operations
        let transactionFee = proposal.envelope.transaction.fee
        var lines: [Line] = []
        var title: LocalizedStringResource = "Treasury transaction"
        var caveat: LocalizedStringResource?

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
                        ? .copy("No limit")
                        : .amount(limit, code: asset.code)
                ))
                lines.append(Line(
                    label: "Reserve",
                    value: .copy("Locks one more base reserve in the treasury")
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

        // A memo is not decoration. For an exchange deposit it decides
        // which customer gets credited, so a payment whose memo went
        // unmentioned is a payment that can land in the wrong hands
        // while every row on the card reads correctly.
        switch proposal.envelope.transaction.memo {
        case .none:
            break
        case .text(let text):
            lines.append(Line(label: "Memo", value: .text(text), isPrincipal: true))
        case .id(let value):
            lines.append(Line(label: "Memo (id)", value: .text(String(value)), isPrincipal: true))
        case .hash(let data), .returnHash(let data):
            lines.append(Line(
                label: "Memo (hash)",
                value: .text(data.map { String(format: "%02x", $0) }.joined()),
                isPrincipal: true
            ))
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
        self.lines = lines.enumerated().map { index, line in
            var numbered = line
            numbered.ordinal = index
            return numbered
        }
        self.caveat = caveat
    }

    /// The `setOptions` operations at the front of the transaction,
    /// stopping at the first operation that is anything else.
    private static func leadingSetOptions(
        _ operations: [StellarOperation]
    ) -> [StellarOperation] {
        Array(operations.prefix { operation in
            if case .setOptions = operation.body { return true }
            return false
        })
    }

    private static func explainedOperationCount(_ operations: [StellarOperation]) -> Int {
        switch operations.first?.body {
        case .setOptions:
            // The control branch reads exactly this run — one helper, so
            // the two cannot drift into disagreeing about which
            // operations were accounted for.
            return leadingSetOptions(operations).count
        case .payment, .changeTrust:
            return 1
        case .createAccount, .none:
            return 0
        }
    }

    /// Signer and threshold changes, which are the proposals worth
    /// reading most carefully — they decide who can spend everything
    /// else.
    /// Account flags, named where the protocol names them.
    ///
    /// `AUTH_IMMUTABLE` is the one to read twice: it freezes the
    /// account's authorisation settings permanently and cannot be
    /// undone by anyone, including everyone at once.
    private static func describeFlags(_ flags: UInt32) -> String {
        var named: [String] = []
        if flags & 0x1 != 0 { named.append("AUTH_REQUIRED") }
        if flags & 0x2 != 0 { named.append("AUTH_REVOCABLE") }
        if flags & 0x4 != 0 { named.append("AUTH_IMMUTABLE (cannot be undone)") }
        if flags & 0x8 != 0 { named.append("AUTH_CLAWBACK_ENABLED") }
        if flags & ~UInt32(0xF) != 0 {
            named.append("flags this app does not recognise")
        }
        return named.isEmpty
            ? "0x\(String(flags, radix: 16))"
            : named.joined(separator: ", ")
    }

    private static func describeControl(
        _ operations: [StellarOperation]
    ) -> (LocalizedStringResource, [Line]) {
        var lines: [Line] = []
        var added: [StellarAccountID] = []
        var removed: [StellarAccountID] = []
        var thresholds: (low: UInt32?, medium: UInt32?, high: UInt32?) = (nil, nil, nil)
        var masterWeight: UInt32?
        var setFlags: UInt32?
        var clearFlags: UInt32?
        var inflationDestination: StellarAccountID?
        var homeDomain: String?

        // The leading run only — the same operations
        // `explainedOperationCount` counts, and deliberately so.
        //
        // Skipping over a non-`setOptions` operation with `continue`
        // meant this read every `setOptions` in the transaction while
        // the count stopped at the first gap. So
        // `[setOptions, payment, setOptions]` drew a line describing the
        // third operation *and* a caveat saying two operations are not
        // shown — a card that contradicts itself about which of the
        // things in front of you it has accounted for. Reading the run
        // is the half to give up: the caveat is what makes the rest
        // visible.
        for operation in Self.leadingSetOptions(operations) {
            guard case .setOptions(let fields) = operation.body else { continue }
            if let signer = fields.signer {
                if signer.weight > 0 { added.append(signer.key) } else { removed.append(signer.key) }
            }
            thresholds.low = fields.lowThreshold ?? thresholds.low
            thresholds.medium = fields.mediumThreshold ?? thresholds.medium
            thresholds.high = fields.highThreshold ?? thresholds.high
            masterWeight = fields.masterWeight ?? masterWeight
            // Read, because `StellarOperation` decodes them precisely so
            // a co-signer can see them — and this function used to read
            // none of the four. A one-operation
            // `setOptions{setFlags: AUTH_IMMUTABLE}` classifies as a
            // control change, so it is *accepted*, and it rendered as
            // the title "Change how many signatures are needed" over an
            // empty details box with the operation counted as explained,
            // so no caveat fired. A tidy summary of a control change it
            // did not describe — and AUTH_IMMUTABLE cannot be undone.
            setFlags = fields.setFlags ?? setFlags
            clearFlags = fields.clearFlags ?? clearFlags
            inflationDestination = fields.inflationDestination ?? inflationDestination
            homeDomain = fields.homeDomain ?? homeDomain
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
                value: masterWeight == 0
                    ? .copy("Stays switched off")
                    : .copy("SWITCHED BACK ON \u{2014} weight \(masterWeight)"),
                isPrincipal: masterWeight != 0
            ))
        }

        if let setFlags {
            lines.append(Line(
                label: "Turns on account flags",
                value: .text(Self.describeFlags(setFlags)),
                isPrincipal: true
            ))
        }
        if let clearFlags {
            lines.append(Line(
                label: "Turns off account flags",
                value: .text(Self.describeFlags(clearFlags)),
                isPrincipal: true
            ))
        }
        if let inflationDestination {
            lines.append(Line(
                label: "Inflation destination",
                value: .account(inflationDestination),
                isPrincipal: true
            ))
        }
        if let homeDomain {
            lines.append(Line(
                label: "Home domain",
                value: homeDomain.isEmpty
                    ? .copy("(cleared)")
                    : .text(homeDomain),
                isPrincipal: true
            ))
        }

        let title: LocalizedStringResource
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
