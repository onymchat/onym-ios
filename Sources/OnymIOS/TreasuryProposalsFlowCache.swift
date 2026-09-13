import OnymIdentity
import OnymTreasuryUI

/// One `TreasuryProposalsFlow` per group, for as long as the identity
/// holding it stays selected.
///
/// The treasury screen and the in-thread block both observe a group's
/// proposals, and the second is hosted inside a `UITableViewCell`
/// content configuration — rebuilt on every dequeue. Without this, each
/// rebuild would construct another flow, each subscribing to the
/// repository's snapshot stream and none ever released.
@MainActor
final class TreasuryProposalsFlowCache {
    private var flows: [String: TreasuryProposalsFlow] = [:]
    private var currentIdentity: IdentityID?

    func flow(for groupID: String) -> TreasuryProposalsFlow? { flows[groupID] }

    func store(_ flow: TreasuryProposalsFlow, for groupID: String) {
        flows[groupID] = flow
    }

    /// Clears **only when the selection actually changes** — the guard
    /// `TreasuryFlowCache` keeps, for the same reason: the identity
    /// stream republishes the unchanged current id on every
    /// identity-list broadcast, so renaming an identity or adding a
    /// second one yields it again. Clearing on those would drop a
    /// proposal flow mid-signature for a founder who changed nothing.
    func setCurrentIdentity(_ id: IdentityID?) {
        guard currentIdentity != id else { return }
        currentIdentity = id
        clear()
    }

    /// Cancels each flow's subscription on the way out. The subscription
    /// is deliberately detached so it survives the thread's row being
    /// recycled, which means the draining task holds the flow: dropping
    /// the reference alone would leave every cleared flow alive and
    /// subscribed to the previous identity's snapshots for the rest of
    /// the run.
    private func clear() {
        for flow in flows.values { flow.stop() }
        flows.removeAll()
    }
}
