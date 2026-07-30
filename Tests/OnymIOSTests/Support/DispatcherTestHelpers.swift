import Foundation
@testable import OnymIOS

extension IncomingMessageDispatcher {
    /// Dispatch and then wait for the slow lane to finish — restores the
    /// pre-lane synchronous-effects contract most dispatcher tests were
    /// written against: after this returns, invitation / group-state
    /// side effects (and any chained retries) have been applied.
    func dispatchAndDrain(
        messageID: String,
        ownerIdentityID: IdentityID,
        payload: Data,
        receivedAt: Date
    ) async {
        await dispatch(
            messageID: messageID,
            ownerIdentityID: ownerIdentityID,
            payload: payload,
            receivedAt: receivedAt
        )
        await drainSlowLane()
    }
}
