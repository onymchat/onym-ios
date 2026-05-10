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
    case shareInvite      // PR-5 deeplink: mint + share intro link
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

    var name: String
    var accent: OnymAccent = .blue
    /// Always `.tyranny` in PR-C — the picker disables the others.
    var governance: OnymUIGovernance = .tyranny
    var invitees: [OnymInvitee] = []

    /// Friendly placeholder generated on init / reset (e.g. "Maple
    /// Garden"). The TextField pre-fills with this so the user can
    /// hit Create immediately without typing — first focus on the
    /// field clears it (see `tappedNameFieldFocused`). Submit also
    /// falls back to this if the user emptied the field and didn't
    /// retype.
    private(set) var generatedName: String

    /// Goes true on the first focus event of the name field. Used to
    /// distinguish "user accepted the placeholder" from "user wants
    /// to type their own".
    private var nameFieldHasBeenFocused = false

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
        let generated = Self.generatePlaceholderName()
        self.generatedName = generated
        self.name = generated
    }

    /// Called by the Step1 view when the name TextField gets focus.
    /// On the *first* focus we clear the field so the user can type a
    /// fresh name without manually deleting the placeholder. After
    /// that, focus is a no-op — the user is in charge of the field.
    func tappedNameFieldFocused() {
        guard !nameFieldHasBeenFocused else { return }
        nameFieldHasBeenFocused = true
        if name == generatedName {
            name = ""
        }
    }

    // MARK: - Step 1 → Step 2

    /// True when a valid governance type is selected. The name can
    /// be empty — submit falls back to `generatedName`. The Step1
    /// "Next" button is enabled whenever governance is available.
    var canAdvanceToStep2: Bool { governance.isAvailable }

    /// What to send to the interactor: the user's typed name if
    /// non-empty, else the placeholder we generated for them.
    var effectiveName: String {
        let trimmed = trimmedName
        return trimmed.isEmpty ? generatedName : trimmed
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
    /// (`Create empty group` / `Create with N people`). For 1-on-1
    /// dialogs the count is implicit so the copy switches to
    /// `Start dialog` / `Add the other person` instead.
    var createCTALabel: String {
        switch governance {
        case .oneOnOne:
            return invitees.isEmpty ? "Add the other person" : "Start dialog"
        case .tyranny, .anarchy:
            if invitees.isEmpty { return "Create empty group" }
            let n = invitees.count
            return "Create with \(n) \(n == 1 ? "person" : "people")"
        }
    }

    /// Whether the Step2 "Create" button should be tappable. Tyranny /
    /// anarchy accept any roster size (including zero); 1-on-1
    /// requires exactly one invitee — the peer.
    var canCreate: Bool {
        switch governance {
        case .oneOnOne: invitees.count == 1
        case .tyranny, .anarchy: true
        }
    }

    /// Whether the Step2 "Invite by inbox key" entry point should be
    /// shown. 1-on-1 caps at one peer, so once the user has added the
    /// peer we hide the row to avoid implying they can add more.
    var canAddMoreInvitees: Bool {
        switch governance {
        case .oneOnOne: invitees.isEmpty
        case .tyranny, .anarchy: true
        }
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

    /// Drop a scanned QR payload into `inviteeInput`. Strips known URL
    /// wrappers so the user sees the raw 64-char hex (or whatever the
    /// payload canonicalises to) and can review before tapping
    /// "Add to group". Validation is left to the existing pipeline —
    /// a malformed scan surfaces the same inline error as a malformed
    /// paste.
    func tappedScannedKey(_ raw: String) {
        inviteeInput = Self.canonicalizeInviteKey(raw)
        inviteeError = nil
    }

    /// Pull a candidate inbox key out of a raw scanned/pasted string.
    /// Recognises:
    ///  - bare hex (returned unchanged, lowercased)
    ///  - `https://onym.chat?payload=<hex>` (legacy iOS settings QR)
    ///  - `https://onym.chat/i?k=<urlsafe-base64>` (Android identity
    ///    invite — `IdentityInviteUrl.kt`)
    /// Falls back to the trimmed raw input otherwise so the existing
    /// validation surfaces a meaningful error.
    static func canonicalizeInviteKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed),
           let items = comps.queryItems {
            if let payload = items.first(where: { $0.name == "payload" })?.value,
               !payload.isEmpty {
                return payload.lowercased()
            }
            if let k = items.first(where: { $0.name == "k" })?.value,
               let bytes = urlSafeBase64Decode(k) {
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
        }
        return trimmed
    }

    private static func urlSafeBase64Decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
        t = t.replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        t.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: t)
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
                governanceType: governance.sepGroupType,
                name: effectiveName,
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

    /// Move from the success screen to the deeplink share screen.
    /// No-op if the group hasn't finished creating yet (the button is
    /// disabled in that state, but defensive against double-tap
    /// races).
    func tappedShareInvite() {
        guard createdGroup != nil else { return }
        route = .shareInvite
    }

    func tappedDismissError() {
        error = nil
        route = .step2
    }

    /// User chose to cancel out of the flow from the error state on
    /// the Creating screen. The group may already be saved on disk
    /// (we save before sending invitations) — leaving it intact is
    /// fine, a future "retry invites" UI can pick it up. Just close
    /// the modal and reset.
    func tappedCancelFromError() {
        reset()
        onClose()
    }

    private func reset() {
        let generated = Self.generatePlaceholderName()
        generatedName = generated
        name = generated
        nameFieldHasBeenFocused = false
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

    /// Build a "Adjective Noun" label like "Maple Garden". Random
    /// pick from a small lexicon picked for being warm + neutral.
    /// Pure function so it's deterministic given the system RNG;
    /// tests that need a stable name can override `generatedName`
    /// directly after init.
    static func generatePlaceholderName() -> String {
        let adjectives = [
            "Maple", "Quiet", "Sunny", "Brave", "Crimson",
            "Velvet", "Northern", "Golden", "Ember", "Wild",
            "Distant", "Tidal", "Silver", "Twilight", "Amber",
        ]
        let nouns = [
            "Garden", "Forest", "Harbor", "Meadow", "Atlas",
            "River", "Cottage", "Lantern", "Compass", "Orchard",
            "Mountain", "Lighthouse", "Plateau", "Valley", "Bay",
        ]
        let a = adjectives.randomElement() ?? "Quiet"
        let n = nouns.randomElement() ?? "Forest"
        return "\(a) \(n)"
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
