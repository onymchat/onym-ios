import Foundation
import OnymIdentity

/// A chat this device has asked to be let into, or been offered a seat
/// in, but is not yet a member of.
///
/// It is deliberately **not** a `ChatGroup`. There is no group secret,
/// no roster and no epoch here — nothing that could decrypt or send —
/// and it must never reach `GroupRepository`: `currentGroups()` is the
/// "do I already hold this group?" oracle for both
/// `JoinRequestApprover` and `IncomingMessageDispatcher.materializeGroup`,
/// so a placeholder there would suppress the real materialization and
/// the "You joined" notice with it. The chats list merges the two kinds
/// of row at the view-model layer instead (`PendingChatsFlow`).
///
/// One row per `(group, owning identity)` rather than per inbound event:
/// an offer replayed by a relay and a link tapped for the same group are
/// the same waiting room, and the user should see one row for it.
public struct PendingChat: Identifiable, Equatable, Sendable {
    /// What this row is waiting on. The verification statuses
    /// (`PendingGroupVerification.Status`) are *not* mirrored here —
    /// they live in `PendingVerificationStore` and are overlaid at read
    /// time by `PendingChatsFlow`, so there is one owner of each fact.
    public enum Status: Equatable, Sendable {
        /// A pushed offer nobody has answered yet. Accept ships the
        /// join request; until then nothing has left this device.
        case offered
        /// The join request is out. Waiting on the founder.
        case requested
        /// The request couldn't be sent. Carries a *code*, not a
        /// sentence: this row is written to disk and outlives the
        /// language it was written in, the same rule
        /// `ChatSystemEvent` follows. The wording is assembled at
        /// render time, in the view.
        case failed(SendFailure)
    }

    /// Why a join request didn't leave the device. Coarse on purpose —
    /// these are the two things a person can act on differently, and a
    /// transport's own error text is neither localizable nor useful to
    /// the reader.
    ///
    /// Raw values are a persistence format: stable forever.
    public enum SendFailure: String, Equatable, Sendable {
        /// No identity was loaded when the send was attempted.
        case noIdentity
        /// The request never reached a relay.
        case transport
    }

    /// `<group id hex>:<owner uuid>` — the dedupe key, and stable across
    /// relaunches (unlike a Nostr event id, which changes per delivery).
    public var id: String { "\(groupIDHex):\(ownerIdentityID.rawValue.uuidString)" }

    /// Lowercase hex of `groupID`. Stored rather than derived at every
    /// call site because it is also how `PendingVerificationStore`
    /// names a group, and the two are matched on it.
    public let groupIDHex: String
    public let groupID: Data
    /// Identity that was invited / did the asking. The join request is
    /// sealed and sent *as* this identity.
    public let ownerIdentityID: IdentityID
    /// The founder's per-invite intro pubkey — the reply channel a join
    /// request is sealed to.
    public let introPublicKey: Data
    public let groupName: String?
    /// Self-asserted, like every alias. Empty for a link/QR join, where
    /// nobody introduced themselves.
    public let inviterAlias: String
    /// The founder's free-text invitation, when the offer carried one.
    public let invitationMessage: String?
    /// When this device first saw the offer or tapped the link — the
    /// row's sort key in the chats list.
    public let receivedAt: Date
    public var status: Status

    /// Bytes from the hex the row stores. Same shape as
    /// `ChatGroup.bytes(fromHex:)`, which reads its own group id back
    /// the same way.
    public static func bytes(fromHex hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        return data
    }

    public init(
        groupID: Data,
        ownerIdentityID: IdentityID,
        introPublicKey: Data,
        groupName: String?,
        inviterAlias: String,
        invitationMessage: String?,
        receivedAt: Date,
        status: Status
    ) {
        self.groupID = groupID
        self.groupIDHex = groupID.map { String(format: "%02x", $0) }.joined()
        self.ownerIdentityID = ownerIdentityID
        self.introPublicKey = introPublicKey
        self.groupName = groupName
        self.inviterAlias = inviterAlias
        self.invitationMessage = invitationMessage
        self.receivedAt = receivedAt
        self.status = status
    }
}

/// Receive-side seam the dispatcher writes decoded offers into. Kept to
/// one method so the dispatcher depends on a narrow protocol rather than
/// the concrete repository.
public protocol PendingChatRecording: Sendable {
    /// Idempotent on `PendingChat.id`. A re-delivered offer keeps the
    /// row it already has — in particular it must not knock a
    /// `.requested` row back to `.offered` and ask the user to accept an
    /// invitation they already accepted.
    @discardableResult
    func record(_ chat: PendingChat) async -> PendingChatWriteOutcome
}

/// What a write actually did.
///
/// Three cases rather than a `Bool` because the deeplink caller acts
/// differently on each: a fresh row is asked for on the user's behalf,
/// an existing one is picked up where it stands, and a write that never
/// landed has to be said out loud rather than leaving someone waiting on
/// a request their device has no record of.
///
/// The dispatcher's offer path ignores it on purpose — see `recordOffer`.
/// A pushed offer is a retained event the relays replay on every
/// reconnect, so the next delivery re-attempts the write; there is
/// nothing for that caller to do with a failure that waiting doesn't
/// already do, and there is nothing it may log (an invitation is exactly
/// the kind of activity this app does not record).
public enum PendingChatWriteOutcome: Equatable, Sendable {
    /// A new waiting room appeared.
    case inserted
    /// A row for this `(group, owner)` was already there and was left
    /// exactly as it was.
    case alreadyPresent
    /// The row could not be written (encryption or store failure). The
    /// user is waiting on something this device has no record of.
    case failed
    /// Nobody was listening — the recorder is a no-op. Distinct from
    /// `.failed` so a test double is never mistaken for a disk that
    /// gave out.
    case notRecorded
}

/// Default `PendingChatRecording` for the many test constructions of
/// `IncomingMessageDispatcher` that never exercise an offer. Production
/// (`OnymIOSApp`) passes the shared `PendingChatRepository` explicitly.
///
/// A no-op rather than a throwaway store: the previous default *did*
/// record, into an instance nobody could read, which looked like working
/// behaviour and was not.
public struct NoopPendingChatRecorder: PendingChatRecording {
    public init() {}

    /// `.notRecorded`, not `.failed`: nothing here ever tries, so
    /// reporting a failure would make a wiring choice look like a disk
    /// that gave out.
    @discardableResult
    public func record(_ chat: PendingChat) async -> PendingChatWriteOutcome { .notRecorded }
}
