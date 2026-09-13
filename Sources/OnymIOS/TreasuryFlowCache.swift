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

    func flow(for groupID: String) -> TreasuryFlow? { flows[groupID] }

    func store(_ flow: TreasuryFlow, for groupID: String) { flows[groupID] = flow }

    func clear() { flows.removeAll() }
}
