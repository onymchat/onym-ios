import OnymIdentity
import OnymTreasuryUI

/// One `TreasuryFlow` per group, for as long as the identity holding it
/// stays selected.
///
/// The treasury screen is built inside a `NavigationLink` destination
/// closure, and `ChatMembersView` re-renders off the group stream —
/// every declaration anyone in the chat makes. Constructing the flow
/// there meant each of those re-renders threw away the typed address,
/// the co-signer ticks and the chosen thresholds, and re-subscribed the
/// snapshot stream.
///
/// Every other flow-backed screen in the app holds its flow in `@State`
/// for this reason. That works when the flow is built once per view;
/// here the factory runs on every render, so the memo has to sit on the
/// producing side.
///
/// **Cleared when the selected identity changes.** A flow holds that
/// identity's `members`, `isAdmin` and `mine`; keeping it across a
/// switch would hand the next identity the previous one's view of the
/// same chat. Clearing is the whole invalidation strategy — entries are
/// cheap to rebuild, and keying on `(identity, group)` instead would
/// need an `async` read the factory closure cannot make.
@MainActor
final class TreasuryFlowCache {
    private var flows: [String: TreasuryFlow] = [:]
    private var currentIdentity: IdentityID?

    func flow(for groupID: String) -> TreasuryFlow? { flows[groupID] }

    func store(_ flow: TreasuryFlow, for groupID: String) { flows[groupID] = flow }

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
    /// funded treasury the group is never told about.
    func setCurrentIdentity(_ id: IdentityID?) {
        guard currentIdentity != id else { return }
        currentIdentity = id
        clear()
    }

    /// Cancels each flow's subscription on the way out. The subscription
    /// is deliberately detached so it survives the screen being popped,
    /// which means the draining task holds the flow: dropping the
    /// reference alone would leave every cleared flow alive and
    /// subscribed to the previous identity's snapshots for the rest of
    /// the run.
    private func clear() {
        for flow in flows.values { flow.stop() }
        flows.removeAll()
    }
}
