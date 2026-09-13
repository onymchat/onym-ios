import OnymTreasuryUI

/// One `TreasuryProposalsFlow` per group, for the lifetime of the app.
///
/// The treasury screen and the in-thread block both observe a group's
/// proposals, and the second is hosted inside a `UITableViewCell`
/// content configuration — rebuilt on every dequeue. Without this, each
/// rebuild would construct another flow, each one subscribing to the
/// repository's snapshot stream and none of them ever released.
///
/// Not a cache in the evictable sense: the entries are small, there is
/// one per group the user has actually opened a treasury surface for,
/// and dropping one while a view still held it would silently stop that
/// view updating.
@MainActor
final class TreasuryProposalsFlowCache {
    var flows: [String: TreasuryProposalsFlow] = [:]
}
