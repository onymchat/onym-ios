import OnymTreasuryUI

/// One `TreasuryFlow` per group — see `IdentityScopedFlowCache` for what
/// the cache does and when it invalidates.
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
typealias TreasuryFlowCache = IdentityScopedFlowCache<TreasuryFlow>
