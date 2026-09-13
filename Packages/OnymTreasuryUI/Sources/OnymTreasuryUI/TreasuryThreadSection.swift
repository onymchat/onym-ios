import OnymDesign
import OnymDesignTokens
import OnymTreasury
import SwiftUI

/// The treasury block inside a chat thread: whatever is waiting on
/// signatures, rendered where the conversation about it is happening.
///
/// This is what "a payment put to the group as something actionable in
/// the thread" comes to. The card is the same one the treasury screen
/// draws, so there is one description of a transaction and not two.
///
/// ## It collapses to nothing
///
/// A thread with no open proposal renders zero height. That matters
/// because the row is always present in the table — the controller does
/// not track proposal state, precisely so that a signature arriving
/// from another member updates this view without anything else being
/// told. The price of that is this view having to be honest about
/// occupying no space when it has nothing to say.
public struct TreasuryThreadSection: View {
    @State private var flow: TreasuryProposalsFlow
    @Environment(\.openURL) private var openURL

    public init(flow: TreasuryProposalsFlow) {
        _flow = State(wrappedValue: flow)
    }

    /// Only what someone can still act on. A submitted or expired
    /// proposal belongs in the treasury's history, not pinned to the
    /// bottom of a conversation forever.
    private var open: [TreasuryProposalRow] {
        flow.rows.filter { row in
            guard let standing = row.standing else { return true }
            return standing.isActionable
        }
    }

    public var body: some View {
        Group {
            if open.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(open.count == 1
                            ? "Treasury \u{2014} waiting on signatures"
                            : "Treasury \u{2014} \(open.count) waiting on signatures")
                            .font(OnymType.font(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(OnymTokens.text3)

                    ForEach(open) { row in
                        TreasuryProposalCard(row: row, flow: flow)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .task { await flow.start() }
        .onChange(of: flow.walletRequest) { _, request in
            guard let url = request?.url else { return }
            openURL(url)
            flow.clearWalletRequest()
        }
        .sheet(isPresented: Binding(
            get: { flow.pasteTargetID != nil && flow.walletRequest == nil },
            set: { if !$0 { flow.pasteTargetID = nil } }
        )) {
            NavigationStack { PasteSignedTransactionView(flow: flow) }
        }
        .reasonAlert("Treasury", reason: Binding(
            get: { flow.actionError },
            set: { if $0 == nil { flow.clearError() } }
        ))
    }
}
