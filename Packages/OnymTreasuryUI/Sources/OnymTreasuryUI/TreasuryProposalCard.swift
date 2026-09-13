import OnymDesign
import OnymDesignTokens
import OnymStellar
import OnymTreasury
import SwiftUI

/// One proposal, as a co-signer sees it.
///
/// The same view in the chat thread and on the treasury screen — one
/// rendering, so the two cannot describe the same transaction
/// differently. Everything it draws comes from
/// `TreasuryProposalDescription`, which is built from the transaction
/// this device decoded; nothing the proposer typed appears anywhere on
/// it, because there is nothing the proposer typed.
public struct TreasuryProposalCard: View {
    let row: TreasuryProposalRow
    @Bindable var flow: TreasuryProposalsFlow
    /// Which surface this card is drawn on, so an external-wallet
    /// handoff is presented by the view the person tapped on rather
    /// than by both views observing this flow.
    let surface: TreasuryProposalsFlow.Surface

    public init(
        row: TreasuryProposalRow,
        flow: TreasuryProposalsFlow,
        surface: TreasuryProposalsFlow.Surface
    ) {
        self.row = row
        self.flow = flow
        self.surface = surface
    }

    private var isBusy: Bool { flow.busyProposalID == row.id }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let caveat = row.description.caveat {
                warning(caveat)
            }
            details
            progress
            actions
        }
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(OnymRadius.shape(OnymRadius.card))
        .overlay(
            OnymRadius.shape(OnymRadius.card)
                .stroke(
                    row.description.caveat == nil ? OnymTokens.hairline : OnymTokens.red,
                    lineWidth: row.description.caveat == nil ? 1 : 1.5
                )
        )
        .accessibilityIdentifier("treasury.proposal.\(row.id.uuidString)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, bg: tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.description.title)
                    .font(OnymType.font(size: 15, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Proposed by \(row.proposerAlias)")
                    .font(OnymType.font(size: 12))
                    .foregroundStyle(OnymTokens.text3)
            }
            Spacer()
        }
    }

    private var symbol: String {
        switch row.standing {
        case .submitted: "checkmark.seal.fill"
        case .superseded, .expired: "clock.badge.xmark"
        case .rejected: "exclamationmark.triangle.fill"
        default: "signature"
        }
    }

    private var tile: Color {
        switch row.standing {
        case .submitted: OnymTile.green
        case .superseded, .expired: OnymTile.gray
        case .rejected: OnymTile.red
        default: OnymTile.blue
        }
    }

    /// The decoded operations, laid out so the parts that decide where
    /// money goes are the parts that catch the eye.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.description.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.label)
                        .font(OnymType.font(size: 11))
                        .foregroundStyle(OnymTokens.text3)
                    value(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(OnymTokens.surface2)
        .clipShape(OnymRadius.shape(OnymRadius.inset))
    }

    @ViewBuilder
    private func value(_ line: TreasuryProposalDescription.Line) -> some View {
        switch line.value {
        case .text(let text):
            // Runtime data — a memo, a domain — so verbatim, never
            // looked up: a stranger's string that happened to match a
            // catalog key would render the translation instead of
            // itself.
            Text(verbatim: text)
                .font(OnymType.font(size: line.isPrincipal ? 15 : 13,
                                    weight: line.isPrincipal ? .semibold : .regular))
                .foregroundStyle(OnymTokens.text)
        case .copy(let resource):
            Text(resource)
                .font(OnymType.font(size: line.isPrincipal ? 15 : 13,
                                    weight: line.isPrincipal ? .semibold : .regular))
                .foregroundStyle(OnymTokens.text)
        case .amount(let amount, let code):
            Text(verbatim: "\(amount.decimalString) \(code)")
                .font(OnymType.mono(size: line.isPrincipal ? 17 : 13,
                                    weight: line.isPrincipal ? .semibold : .regular))
                .foregroundStyle(OnymTokens.text)
                .monospacedDigit()
        case .account(let account):
            // Full address, monospaced, selectable. An abbreviated
            // recipient is one nobody can actually check, and checking
            // the recipient is the single most important thing a
            // co-signer does.
            Text(account.accountID)
                .font(OnymType.mono(size: 12))
                .foregroundStyle(OnymTokens.text)
                .textSelection(.enabled)
                // Wrapped in full, never truncated: a recipient address
                // that ends in an ellipsis is one nobody can check, and
                // checking it is the most important thing a co-signer
                // does on this card.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warning(_ text: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OnymTokens.red)
            Text(text)
                .font(OnymType.font(size: 13, weight: .medium))
                .foregroundStyle(OnymTokens.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(OnymTokens.red.opacity(0.10))
        .clipShape(OnymRadius.shape(OnymRadius.inset))
        .accessibilityIdentifier("treasury.proposal.caveat")
    }

    @ViewBuilder
    private var progress: some View {
        switch row.standing {
        case .none:
            Text("Checking with the network\u{2026}")
                .font(OnymType.font(size: 12))
                .foregroundStyle(OnymTokens.text3)

        case .collecting(let weight, let required):
            VStack(alignment: .leading, spacing: 4) {
                // Cast so the catalog placeholder is unambiguously
                // `%lld`: SwiftUI's placeholder for a `UInt32` is not
                // the one a translator would guess, and the key has to
                // match what the catalog holds exactly.
                Text("\(Int(weight)) of \(Int(required)) signatures")
                    .font(OnymType.font(size: 13, weight: .medium))
                    .foregroundStyle(OnymTokens.text2)
                if !row.waitingOn.isEmpty {
                    Text("Waiting on \(row.waitingOn.joined(separator: ", "))")
                        .font(OnymType.font(size: 12))
                        .foregroundStyle(OnymTokens.text3)
                }
            }

        case .ready:
            Chip(key: "Ready to send", fg: OnymTokens.green, bg: OnymTokens.green.opacity(0.14))

        case .submitted(let hash):
            VStack(alignment: .leading, spacing: 4) {
                Chip(key: "Sent", fg: OnymTokens.green, bg: OnymTokens.green.opacity(0.14))
                Text(hash)
                    .font(OnymType.mono(size: 11))
                    .foregroundStyle(OnymTokens.text3)
                    .textSelection(.enabled)
                    .onymLineLimit(1, relaxing: false)
            }

        case .superseded:
            Text("Another transaction went first, so this one can never be used. It needs proposing again.")
                .font(OnymType.font(size: 12))
                .foregroundStyle(OnymTokens.text3)

        case .expired:
            Text("Expired without enough signatures.")
                .font(OnymType.font(size: 12))
                .foregroundStyle(OnymTokens.text3)

        case .rejected(let reason):
            Text(explain(reason))
                .font(OnymType.font(size: 12, weight: .medium))
                .foregroundStyle(OnymTokens.red)

        case .dismissed:
            Text("Set aside on this phone. It isn't holding up other proposals.")
                .font(OnymType.font(size: 12))
                .foregroundStyle(OnymTokens.text3)
        }
    }

    /// Each refusal says what was actually wrong. "Invalid" would leave
    /// a member unable to tell a peer on the wrong network setting from
    /// someone trying something.
    private func explain(_ reason: TreasuryRejection) -> LocalizedStringKey {
        switch reason {
        case .notThisTreasury:
            "This spends a different account, not this chat's treasury. It was not shown for signing."
        case .wrongNetwork:
            "This was built for a different Stellar network."
        case .unsupportedOperation:
            "This asks for something this app can't read, so it can't show you what you'd be signing."
        case .foreignOperationSource:
            "This also acts on an account that isn't the treasury."
        case .proposerNotAMember:
            "Whoever sent this isn't a member of this chat."
        case .malformed:
            "This transaction couldn't be read."
        case .noTreasury:
            "This chat has no treasury."
        case .excessiveFee:
            "This offers a network fee far above the going rate \u{2014} assets leaving the treasury that none of the rows above would show."
        case .noExpiry:
            "This never expires. It would hold the treasury's next slot for good, so nothing else could ever be sent."
        case .expiresTooLate:
            "This stays valid far longer than a proposal should."
        case .tooManySignatures:
            "This arrived already carrying so many signatures that there is no room left for the people who still have to sign."
        case .implausibleSequence:
            "This claims a slot far beyond the treasury's next one, which would block everything else until it expired."
        }
    }

    @ViewBuilder
    private var actions: some View {
        if row.standing == .dismissed {
            Button {
                Task { await flow.restore(row.id) }
            } label: {
                Text("Put it back")
                    .font(OnymType.font(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityIdentifier("treasury.proposal.restore.\(row.id.uuidString)")
        } else if row.canSign || row.canSubmit {
            HStack(spacing: 10) {
                if row.canSign {
                    Button {
                        Task { await flow.sign(row.id, from: surface) }
                    } label: {
                        Text("Sign")
                            .font(OnymType.font(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                    .accessibilityIdentifier("treasury.proposal.sign.\(row.id.uuidString)")
                }
                if row.canSubmit {
                    Button {
                        Task { await flow.submit(row.id, from: surface) }
                    } label: {
                        Text("Send it")
                            .font(OnymType.font(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OnymTokens.green)
                    .disabled(isBusy)
                    .accessibilityIdentifier("treasury.proposal.submit.\(row.id.uuidString)")
                }
            }
            // Deliberately plain and next to the actions rather than
            // hidden in a menu: an open proposal holds the treasury's
            // next slot, so "we've decided against this one" needs to be
            // as reachable as signing it. It changes nothing for anyone
            // else and is undone by the button that replaces it.
            Button {
                Task { await flow.dismiss(row.id) }
            } label: {
                Text("Set aside")
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text3)
            }
            .disabled(isBusy)
            .accessibilityIdentifier("treasury.proposal.dismiss.\(row.id.uuidString)")
        }
        if !row.signedBy.isEmpty {
            Text("Signed by \(row.signedBy.joined(separator: ", "))")
                .font(OnymType.font(size: 12))
                .foregroundStyle(OnymTokens.text3)
        }
    }
}
