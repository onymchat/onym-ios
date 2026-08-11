import Foundation
import OnymChain
import OnymIdentity

/// Seam for appending a locally-minted membership notice to a group's
/// chat thread.
///
/// Exists because the dependency graph runs `OnymChatsCore → OnymGroup`,
/// so `JoinRequestApprover` (here, in OnymGroup) cannot reach
/// `MessageRepository` directly without a cycle. The production
/// conformer is `ChatSystemEventRecorder` in OnymChatsCore, which is
/// also what `IncomingMessageDispatcher` uses directly — so every system
/// row in the app is minted by exactly one piece of code, with one
/// id-derivation rule.
///
/// Defaulted to `NoopGroupSystemEventRecorder` at the injection site so
/// the many existing test constructions of `JoinRequestApprover` don't
/// have to thread a recorder they never assert on.
public protocol GroupSystemEventRecording: Sendable {
    /// Append "<alias> joined" to `groupID`'s thread as seen by
    /// `ownerIdentityID`. Idempotent on `(groupID, joinerBlsPubkeyHex)`
    /// — a caller that fires twice for the same joiner produces one row.
    func recordMemberJoined(
        groupID: String,
        ownerIdentityID: IdentityID,
        groupType: SEPGroupType,
        joinerBlsPubkeyHex: String,
        alias: String,
        at: Date
    ) async
}

/// Drops every notice. Test/default seam, mirroring
/// `NoopChatReceiptSender` and `NoopGroupStateRefresher`.
public struct NoopGroupSystemEventRecorder: GroupSystemEventRecording {
    public init() {}

    public func recordMemberJoined(
        groupID: String,
        ownerIdentityID: IdentityID,
        groupType: SEPGroupType,
        joinerBlsPubkeyHex: String,
        alias: String,
        at: Date
    ) async {}
}
