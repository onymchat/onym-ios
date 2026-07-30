import Foundation

/// What this device has already decided about a group invite, keyed by
/// the *logical* invite `(owner identity, group id)` — deliberately not
/// the Nostr event id, so a re-broadcast offer under a fresh event id
/// for a group the user already acted on is still recognized.
enum InviteDisposition: String, Codable, Sendable {
    /// Offer surfaced, awaiting the user's Accept / Dismiss.
    case offered
    /// User accepted: a join request was sent, awaiting the admin's
    /// approval. Survives relaunch — the UI shows an honest
    /// "request sent, awaiting approval" row instead of re-offering.
    case requested
    /// User dismissed the offer. Sticky: re-delivered offers stay dropped.
    case declined
    /// The group materialized locally — the invite is spent.
    case joined

    /// Monotonic rank: a disposition only ever moves forward, so a
    /// re-delivered stale offer can never resurrect a handled invite.
    /// `requested` and `declined` share a rank (mutually exclusive user
    /// choices); `joined` is terminal.
    var rank: Int {
        switch self {
        case .offered: return 0
        case .requested, .declined: return 1
        case .joined: return 2
        }
    }
}

/// One ledger row, carrying enough display metadata to render the
/// "awaiting approval" surface without the original offer event.
struct InviteDispositionEntry: Codable, Equatable, Sendable, Identifiable {
    let ownerIdentityID: String
    let groupIDHex: String
    var state: InviteDisposition
    var groupName: String?
    var inviterAlias: String?
    var updatedAt: Date

    var id: String { "\(ownerIdentityID)|\(groupIDHex)" }
}

/// Narrow write/read seam the dispatcher depends on (mirrors
/// `PendingInvitesRecording`).
protocol InviteDispositionStoring: Sendable {
    func disposition(owner: IdentityID, groupID: Data) async -> InviteDisposition?
    func record(
        _ state: InviteDisposition,
        owner: IdentityID,
        groupID: Data,
        groupName: String?,
        inviterAlias: String?
    ) async
}

/// Persisted, per-identity-filtered ledger of invite dispositions.
/// The durable "I already handled this" record the relay can't provide:
/// a Nostr relay is a store, not a queue — it may re-serve an invite
/// offer forever, so the client must own the disposition state. Mirrors
/// the snapshot/filter shape of `PendingInvitesStore`.
actor InviteDispositionLedger: InviteDispositionStoring {
    private let defaults: UserDefaults
    private var entries: [String: InviteDispositionEntry]
    private var currentIdentity: IdentityID?
    private var continuations: [UUID: AsyncStream<[InviteDispositionEntry]>.Continuation] = [:]
    private static let key = "app.onym.ios.inbox.inviteDispositions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([InviteDispositionEntry].self, from: data) {
            self.entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            self.entries = [:]
        }
    }

    // MARK: - InviteDispositionStoring

    func disposition(owner: IdentityID, groupID: Data) -> InviteDisposition? {
        entries[Self.entryID(owner: owner, groupID: groupID)]?.state
    }

    /// Record a disposition. Monotonic: writes that don't advance the
    /// rank are ignored (a re-delivered offer can't downgrade
    /// `requested` back to `offered`). Metadata is refreshed when
    /// provided so later states keep the best-known display strings.
    func record(
        _ state: InviteDisposition,
        owner: IdentityID,
        groupID: Data,
        groupName: String?,
        inviterAlias: String?
    ) {
        let id = Self.entryID(owner: owner, groupID: groupID)
        if var existing = entries[id] {
            guard state.rank > existing.state.rank else {
                // Same-or-lower rank: keep the state, still absorb
                // fresher metadata (e.g. a renamed group on a re-offer).
                var changed = false
                if let groupName, existing.groupName != groupName {
                    existing.groupName = groupName; changed = true
                }
                if let inviterAlias, existing.inviterAlias != inviterAlias {
                    existing.inviterAlias = inviterAlias; changed = true
                }
                if changed { entries[id] = existing; persistAndPublish() }
                return
            }
            existing.state = state
            existing.updatedAt = Date()
            if let groupName { existing.groupName = groupName }
            if let inviterAlias { existing.inviterAlias = inviterAlias }
            entries[id] = existing
        } else {
            entries[id] = InviteDispositionEntry(
                ownerIdentityID: owner.rawValue.uuidString,
                groupIDHex: Self.hex(groupID),
                state: state,
                groupName: groupName,
                inviterAlias: inviterAlias,
                updatedAt: Date()
            )
        }
        persistAndPublish()
    }

    // MARK: - Identity scoping (mirrors PendingInvitesStore)

    func setCurrentIdentity(_ id: IdentityID?) {
        currentIdentity = id
        publish()
    }

    /// Cascade for the identity-removal flow.
    func removeForOwner(_ id: IdentityID) {
        let owner = id.rawValue.uuidString
        let before = entries.count
        entries = entries.filter { $0.value.ownerIdentityID != owner }
        if entries.count != before { persistAndPublish() }
    }

    /// Hot stream of the current identity's entries, newest first.
    nonisolated var snapshots: AsyncStream<[InviteDispositionEntry]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    static func entryID(owner: IdentityID, groupID: Data) -> String {
        "\(owner.rawValue.uuidString)|\(hex(groupID))"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<[InviteDispositionEntry]>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(filtered())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func filtered() -> [InviteDispositionEntry] {
        guard let currentIdentity else { return [] }
        let owner = currentIdentity.rawValue.uuidString
        return entries.values
            .filter { $0.ownerIdentityID == owner }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistAndPublish() {
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            defaults.set(data, forKey: Self.key)
        }
        publish()
    }

    private func publish() {
        let snapshot = filtered()
        for continuation in continuations.values { continuation.yield(snapshot) }
    }
}

/// Default for the dispatcher's seam: records nothing, reports nothing —
/// existing tests construct dispatchers without threading a ledger.
struct NoopInviteDispositionStore: InviteDispositionStoring {
    func disposition(owner: IdentityID, groupID: Data) async -> InviteDisposition? { nil }
    func record(
        _ state: InviteDisposition,
        owner: IdentityID,
        groupID: Data,
        groupName: String?,
        inviterAlias: String?
    ) async {}
}
