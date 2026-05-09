import Foundation
import Observation

/// Stateless interactor for the Chats tab. Drains
/// `GroupRepository.snapshots` into `state.groups`; the view reads
/// from `state` and re-renders on every push. The only mutating
/// intent is `delete(groupID:)`; the create-group entry point is
/// owned by the view's `.fullScreenCover`.
///
/// Mirrors `AnchorsPickerFlow`'s shape: own a `snapshotTask`,
/// idempotent `start()`, plain `stop()`.
@MainActor
@Observable
final class ChatsFlow {
    private(set) var groups: [ChatGroup] = []

    private let repository: GroupRepository
    private var snapshotTask: Task<Void, Never>?

    init(repository: GroupRepository) {
        self.repository = repository
    }

    /// Begin draining repository snapshots. Idempotent.
    func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.groups = snapshot
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    /// Delete a group from the on-device store. The repository emits a
    /// fresh snapshot, so the view drops the row reactively without
    /// needing an optimistic local edit.
    func delete(groupID: String) {
        Task { await repository.delete(id: groupID) }
    }
}
