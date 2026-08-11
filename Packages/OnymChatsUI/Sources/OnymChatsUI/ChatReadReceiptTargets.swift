import Foundation
import OnymChatsCore

/// Which rows in an on-screen thread still owe their sender a `.read`
/// receipt, grouped by sender BLS pubkey hex.
///
/// Pulled out of `ChatThreadView.sendReadReceipts` so the filter can be
/// tested directly: it decides what leaves the device, and getting it
/// wrong is silent — nothing in the UI shows a receipt that shouldn't
/// have been sent.
enum ChatReadReceiptTargets {

    /// Incoming, not-yet-acked, non-system rows, keyed by sender.
    ///
    /// The system-row exclusion is the subtle one. Notices are stored
    /// `.incoming` and carry a **real** member's BLS hex — the joiner's
    /// for "X joined", and this device's own key for "You joined" — and
    /// both resolve in `memberProfiles`. Without the `isSystem` skip,
    /// merely opening a thread would ship a `.read` receipt for a
    /// locally-minted UUID that no other device has ever seen, and the
    /// "you joined" row would address one to yourself. Worst case: a
    /// brand-new group with no real messages emits relay traffic the
    /// moment it's opened.
    ///
    /// This is the receipts half of the same invariant
    /// `ChatSystemEventRecorder` states for its rows: `.incoming` +
    /// `.received` is meant to keep a notice off every *outgoing* path.
    static func unacked(
        in snapshot: [ChatMessage],
        alreadyAcked: Set<UUID>
    ) -> [String: [UUID]] {
        var bySender: [String: [UUID]] = [:]
        for message in snapshot
        where message.direction == .incoming
            && !message.isSystem
            && !alreadyAcked.contains(message.id) {
            bySender[message.senderBlsPubkeyHex, default: []].append(message.id)
        }
        return bySender
    }
}
