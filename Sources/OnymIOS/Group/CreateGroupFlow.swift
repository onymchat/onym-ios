import Foundation
import Observation

/// The five routes the design's flow walks through. Each screen
/// renders based on `flow.route`; transitions are driven by
/// view-side intents (next, back, addInvitee, submit, etc).
enum CreateGroupRoute: Equatable, Sendable {
    case step1            // name + accent + governance
    case step2            // review invitees + create
    case inviteByKey      // paste 64-char inbox key
    case creating         // progress steps
    case success          // hero + members + done
}

/// One pasted-and-validated invitee. The 32-byte X25519 key is what
/// the interactor needs; the hex-prefix label is what the UI
/// renders (full hex is too long for a row).
struct OnymInvitee: Equatable, Identifiable, Sendable {
    let id: UUID
    let inboxPublicKey: Data  // 32 bytes
    /// Cached hex prefix for display ("a4f9b2…51"). Computed once at
    /// add time so the SwiftUI list doesn't re-derive on every row.
    let displayLabel: String
}

/// `@Observable @MainActor` driver for the five screens. Owns the
/// form state, drives navigation, and runs the interactor pipeline.
/// SwiftUI views read fields directly and call intent methods on tap.
@MainActor
@Observable
final class CreateGroupFlow {
    // MARK: - Form state

    var name: String = ""
    var accent: OnymAccent = .blue
    /// Always `.tyranny` in PR-C — the picker disables the others.
    var governance: OnymUIGovernance = .tyranny
    var invitees: [OnymInvitee] = []

    /// Bound to the InviteByKey screen's TextField.
    var inviteeInput: String = ""
    /// Inline error shown under the InviteByKey TextField. Cleared on
    /// every keystroke.
    var inviteeError: String?

    // MARK: - Navigation + pipeline

    var route: CreateGroupRoute = .step1
    var progress: CreateGroupProgress?
    /// Set when the interactor throws. Surface as a banner / inline
    /// error in the Creating / Step1 / Step2 screens.
    var error: CreateGroupError?
    /// Populated when the pipeline finishes — drives Success screen
    /// content (name + member count come from here, not `self.name`,
    /// in case the user edits after submit).
    var createdGroup: ChatGroup?

    /// Tapped Cancel/Close from any screen — host (sheet presenter)
    /// dismisses.
    var onClose: @MainActor () -> Void = {}

    private let interactor: CreateGroupInteractor

    init(interactor: CreateGroupInteractor) {
        self.interactor = interactor
    }

    // MARK: - Step 1 → Step 2

    /// True when the name is non-empty and a valid governance type
    /// is selected. Disables the Step1 "Next" button.
    var canAdvanceToStep2: Bool {
        !trimmedName.isEmpty && governance.isAvailable
    }

    func tappedNext() {
        guard canAdvanceToStep2 else { return }
        route = .step2
    }

    // MARK: - Step 2

    func tappedInviteByKey() {
        inviteeInput = ""
        inviteeError = nil
        route = .inviteByKey
    }

    func tappedBackFromStep2() {
        route = .step1
    }

    func removeInvitee(at index: Int) {
        guard invitees.indices.contains(index) else { return }
        invitees.remove(at: index)
    }

    /// Label for the primary "Create" CTA. Mirrors the design
    /// (`Create empty group` / `Create with N people`).
    var createCTALabel: String {
        if invitees.isEmpty { return "Create empty group" }
        let n = invitees.count
        return "Create with \(n) \(n == 1 ? "person" : "people")"
    }

    // MARK: - InviteByKey

    func tappedAddInvitee() {
        let cleaned = inviteeInput.replacingOccurrences(
            of: "\\s+",
            with: "",
            options: .regularExpression
        )
        guard !cleaned.isEmpty else {
            inviteeError = "Paste an inbox key to continue."
            return
        }
        guard cleaned.count == 64 else {
            inviteeError = "Inbox keys are 64 characters. You pasted \(cleaned.count)."
            return
        }
        guard let raw = Data(hex: cleaned), raw.count == 32 else {
            inviteeError = "That doesn\u{2019}t look like a valid inbox key."
            return
        }
        let prefix = cleaned.prefix(6)
        let suffix = cleaned.suffix(4)
        let invitee = OnymInvitee(
            id: UUID(),
            inboxPublicKey: raw,
            displayLabel: "\(prefix)\u{2026}\(suffix)"
        )
        invitees.append(invitee)
        inviteeInput = ""
        inviteeError = nil
        route = .step2
    }

    func tappedCancelInviteByKey() {
        route = .step2
    }

    /// Live char count for the InviteByKey field — matches the
    /// design's `(43/64)` chip.
    var inviteeInputCleanedLength: Int {
        inviteeInput.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).count
    }

    var inviteeInputIsValid: Bool {
        let cleaned = inviteeInput.replacingOccurrences(
            of: "\\s+",
            with: "",
            options: .regularExpression
        )
        return cleaned.count == 64 && Data(hex: cleaned)?.count == 32
    }

    // MARK: - Submit

    func tappedCreate() {
        Task { await submit() }
    }

    /// Run the interactor pipeline. Updates `progress` from each
    /// `CreateGroupProgress` event the interactor reports, then
    /// transitions to `.success` on completion or sets `error` on
    /// failure. Public for tests; production code dispatches via
    /// `tappedCreate`.
    func submit() async {
        guard governance.isAvailable else {
            error = .noContractBinding(governance.sepGroupType.governanceType)
            return
        }
        error = nil
        progress = .validating
        route = .creating

        do {
            let invitees = self.invitees.map(\.inboxPublicKey)
            let group = try await interactor.create(
                name: name,
                invitees: invitees,
                onProgress: { [weak self] p in
                    Task { @MainActor in self?.progress = p }
                }
            )
            createdGroup = group
            progress = nil
            route = .success
        } catch let err as CreateGroupError {
            error = err
            progress = nil
            // Stay on .creating to show the error banner; the user
            // can dismiss back to step2/step1 from there.
        } catch {
            self.error = .sdkFailure(String(describing: error))
            progress = nil
        }
    }

    // MARK: - Success / reset

    func tappedDone() {
        reset()
        onClose()
    }

    func tappedDismissError() {
        error = nil
        route = .step2
    }

    private func reset() {
        name = ""
        accent = .blue
        governance = .tyranny
        invitees = []
        inviteeInput = ""
        inviteeError = nil
        progress = nil
        error = nil
        createdGroup = nil
        route = .step1
    }

    // MARK: - Helpers

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SEPGroupType ↔ GovernanceType bridge

private extension SEPGroupType {
    /// Bridges to the GovernanceType used by `CreateGroupError.noContractBinding`.
    var governanceType: GovernanceType {
        switch self {
        case .anarchy: .anarchy
        case .oneOnOne: .oneonone
        case .democracy: .democracy
        case .oligarchy: .oligarchy
        case .tyranny: .tyranny
        }
    }
}

// MARK: - Hex decoding

private extension Data {
    init?(hex: String) {
        let cleaned = hex.lowercased()
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
