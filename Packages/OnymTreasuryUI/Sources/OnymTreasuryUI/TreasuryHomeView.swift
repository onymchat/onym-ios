import OnymTreasury
import SwiftUI

/// The one entry point behind the members screen's treasury row.
///
/// Which screen a group needs depends on whether it has a treasury yet,
/// and that is not known when the row is built — so the decision is
/// made here, on state, rather than by two different rows that would
/// each be wrong half the time.
public struct TreasuryHomeView: View {
    @State private var setup: TreasuryFlow
    @State private var proposals: TreasuryProposalsFlow

    public init(setup: TreasuryFlow, proposals: TreasuryProposalsFlow) {
        _setup = State(wrappedValue: setup)
        _proposals = State(wrappedValue: proposals)
    }

    public var body: some View {
        Group {
            if setup.treasury == nil {
                // No treasury: the screen is about getting one, or about
                // saying which account you would sign with when there is.
                TreasurySetupView(flow: setup)
            } else {
                TreasuryView(flow: proposals)
                    // Reachable from here rather than duplicated: the
                    // roster and "your account" still matter after a
                    // treasury exists, and changing your declared
                    // account is how a member moves wallets.
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                TreasurySetupView(flow: setup)
                            } label: {
                                Image(systemName: "person.2.badge.key")
                            }
                            .accessibilityLabel("Signers")
                            .accessibilityIdentifier("treasury.signers")
                        }
                    }
            }
        }
        // Started here as well as inside each child: the branch above
        // reads `setup.treasury`, so the stream has to be draining
        // before either screen is chosen. `start()` is idempotent.
        .task { await setup.start() }
    }
}
