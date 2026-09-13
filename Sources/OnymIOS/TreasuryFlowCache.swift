import OnymTreasuryUI

/// One `TreasuryFlow` per group, for the lifetime of the app.
///
/// The treasury screen is built inside a `NavigationLink` destination
/// closure, and `ChatMembersView` re-renders off the group stream —
/// every declaration anyone in the chat makes. Constructing the flow
/// there meant each of those re-renders threw away the typed address,
/// the co-signer ticks and the chosen thresholds, and re-subscribed the
/// snapshot stream.
///
/// Every other flow-backed screen in the app holds its flow in
/// `@State` for this reason. That works when the flow is built once per
/// view; here the factory is called from a closure that runs on every
/// render, so the memo has to sit on the producing side.
@MainActor
final class TreasuryFlowCache {
    var flows: [String: TreasuryFlow] = [:]
}
