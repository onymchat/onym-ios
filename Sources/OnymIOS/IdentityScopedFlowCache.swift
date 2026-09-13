import OnymIdentity
import OnymTreasuryUI

/// A flow holding a subscription that outlives the view which opened it,
/// and so has to be told to end it.
///
/// Every flow in the app that subscribes from an unstructured `Task`
/// already has this method for that reason; this protocol only names the
/// part `IdentityScopedFlowCache` needs.
@MainActor
protocol StoppableFlow: AnyObject {
    func stop()
}

extension TreasuryFlow: StoppableFlow {}
extension TreasuryProposalsFlow: StoppableFlow {}

/// One `Flow` per group, for as long as the identity holding it stays
/// selected.
///
/// **Cleared when the selected identity changes.** A flow holds that
/// identity's view of the group — its members, its standing, what it is
/// allowed to do; keeping it across a switch would hand the next
/// identity the previous one's view of the same chat. Clearing is the
/// whole invalidation strategy — entries are cheap to rebuild, and
/// keying on `(identity, group)` instead would need an `async` read the
/// factory closures in `OnymIOSApp` cannot make.
///
/// This is generic because it was not, twice over. `TreasuryFlowCache`
/// and `TreasuryProposalsFlowCache` were written as two copies of one
/// shape, and three defects in a row — `start()`'s re-entry guard, then
/// this invalidation, then the cancellation below — were found in one
/// copy and fixed only there. A shared shape does not stay in sync; a
/// shared implementation cannot drift.
@MainActor
final class IdentityScopedFlowCache<Flow: StoppableFlow> {
    private var flows: [String: Flow] = [:]
    private var currentIdentity: IdentityID?

    func flow(for groupID: String) -> Flow? { flows[groupID] }

    func store(_ flow: Flow, for groupID: String) { flows[groupID] = flow }

    /// Every live flow. For the few events that arrive without a group
    /// to route them by — a wallet returning a signed transaction
    /// through `onym://tx` names no group, so the flow that asked for it
    /// has to be found by asking each one.
    var allFlows: [Flow] { Array(flows.values) }

    /// Clears **only when the selection actually changes**, the same
    /// equality guard `TreasuryRepository.setCurrentIdentity` and its
    /// siblings keep — and for a sharper reason here, because the
    /// identity stream republishes the unchanged current id on every
    /// identity-list broadcast: renaming an identity or adding a second
    /// one yields it again. Clearing on those would throw away exactly
    /// what the memo exists to hold, mid-setup — the typed address, the
    /// co-signer ticks, the thresholds, and the `awaitingWallet` stage
    /// that is the only route back to `confirmExternalCreation()`. A
    /// founder whose wallet had already submitted would be left with a
    /// funded treasury the group is never told about, or a proposal
    /// dropped mid-signature having changed nothing.
    func setCurrentIdentity(_ id: IdentityID?) {
        guard currentIdentity != id else { return }
        currentIdentity = id
        clear()
    }

    /// Cancels each flow's subscription on the way out. The subscription
    /// is deliberately detached so it survives the view being torn down
    /// — the screen popped, the thread's row recycled — which means the
    /// draining task holds the flow: dropping the reference alone would
    /// leave every cleared flow alive and subscribed to the previous
    /// identity's snapshots for the rest of the run.
    private func clear() {
        for flow in flows.values { flow.stop() }
        flows.removeAll()
    }
}
