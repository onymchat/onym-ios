import Foundation
import OnymChatsCore
import OnymIdentity

/// Holding pen for chat messages that arrived before the local state
/// they depend on.
///
/// Relays replay the stored inbox newest-first, so after a store loss
/// (or on any fresh device) chat messages routinely land *before* the
/// `GroupInvitationPayload` that materializes their group or the
/// `MemberAnnouncementPayload` that adds their sender to the roster.
/// The dispatcher used to drop such messages silently, which turned
/// the relay's full-history replay into a one-shot lottery: only
/// messages that happened to arrive after their group materialized
/// survived. Parking them here and re-driving them when the group or
/// roster catches up turns that replay into a real backfill.
///
/// Session-scoped by design: the replay that delivers an orphaned
/// message delivers its group in the same subscription, and a launch
/// that dies mid-replay gets the full replay again on the next
/// connect (the inbox REQ is unbounded).
public actor ChatMessageParkingLot {
    struct Entry: Sendable {
        let groupIDHex: String
        let payload: ChatMessagePayload
        let ownerIdentityID: IdentityID
        let senderEd25519PublicKey: Data
    }

    /// Oldest entries are evicted first past this cap — a bound on
    /// replay-burst memory, not a correctness knob. At the default
    /// cap a full drop-and-repark cycle stays far below the size of
    /// any realistic single-group backlog.
    private let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int = 2048) {
        self.capacity = capacity
    }

    func park(_ entry: Entry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Remove and return every parked message for `groupIDHex`, in
    /// arrival order. The caller re-drives them through the normal
    /// persist path; any that are still blocked re-park themselves.
    func takeMatching(groupIDHex: String) -> [Entry] {
        let matching = entries.filter { $0.groupIDHex == groupIDHex }
        guard !matching.isEmpty else { return [] }
        entries.removeAll { $0.groupIDHex == groupIDHex }
        return matching
    }
}
