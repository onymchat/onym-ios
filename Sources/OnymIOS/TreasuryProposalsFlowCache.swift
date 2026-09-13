import OnymTreasuryUI

/// One `TreasuryProposalsFlow` per group — see `IdentityScopedFlowCache`
/// for what the cache does and when it invalidates.
///
/// The treasury screen and the in-thread block both observe a group's
/// proposals, and the second is hosted inside a `UITableViewCell`
/// content configuration — rebuilt on every dequeue. Without this, each
/// rebuild would construct another flow, each subscribing to the
/// repository's snapshot stream and none ever released.
typealias TreasuryProposalsFlowCache = IdentityScopedFlowCache<TreasuryProposalsFlow>
