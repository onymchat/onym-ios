import Foundation
import OnymModeration

/// Backs Settings → Moderation: the active mandate, the read-only
/// mandate history, and the entry point into the switching consent
/// flow. Pure snapshot drain — all mutations go through
/// `ModerationConsentFlow.consent`.
@MainActor
@Observable
public final class ModerationSettingsFlow {
    public struct State: Equatable {
        public var snapshot: ModerationState = .empty
        public var openCases: [CaseNotice] = []
    }

    public private(set) var state = State()

    private let repository: ModerationRepository
    private let gateCheck: GateCheckRepository
    private var snapshotTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?

    public init(repository: ModerationRepository, gateCheck: GateCheckRepository) {
        self.repository = repository
        self.gateCheck = gateCheck
    }

    public func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.state.snapshot = snapshot
            }
        }
        gateTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.gateCheck.snapshots {
                // Assign on every status, not just `.operational`:
                // keeping the last-seen notices when the gate moves
                // elsewhere would leave a closed case on screen.
                switch status {
                case .operational(let openCases):
                    self.state.openCases = openCases
                case .notMandated, .banned, .gateCheckRequired:
                    self.state.openCases = []
                }
            }
        }
    }

    public func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        gateTask?.cancel()
        gateTask = nil
    }

    // MARK: - Read helpers

    public var activeMandate: MandateRecord? {
        state.snapshot.activeMandate
    }

    /// Deactivated records, newest first — each still pinned to the
    /// manifest hash it consented to.
    public var previousMandates: [MandateRecord] {
        state.snapshot.history.filter { !$0.isActive }
    }
}
