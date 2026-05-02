import Foundation
@testable import OnymIOS

/// `InvitationStore` impl for tests that don't need to exercise the
/// SwiftData backend itself — much faster (no `ModelContainer`
/// initialisation per test) and lets the test focus on the seam
/// contract instead of CRUD plumbing.
///
/// Pair with `SwiftDataInvitationStoreTests` (which DOES exercise the
/// real backend) to get full coverage cheaply.
actor InMemoryInvitationStore: InvitationStore {
    private var rows: [String: IncomingInvitationRecord] = [:]

    func list() -> [IncomingInvitationRecord] {
        rows.values.sorted { $0.receivedAt > $1.receivedAt }
    }

    @discardableResult
    func save(_ record: IncomingInvitationRecord) -> Bool {
        if rows[record.id] != nil { return false }
        rows[record.id] = record
        return true
    }

    func updateStatus(id: String, status: IncomingInvitationStatus) {
        guard var existing = rows[id] else { return }
        existing = IncomingInvitationRecord(
            id: existing.id,
            payload: existing.payload,
            receivedAt: existing.receivedAt,
            status: status
        )
        rows[id] = existing
    }

    func delete(id: String) {
        rows.removeValue(forKey: id)
    }
}
