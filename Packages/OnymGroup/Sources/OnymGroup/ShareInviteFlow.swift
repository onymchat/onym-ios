import Foundation
import Observation
import OnymIdentity

/// Drives the post-create "Share invite" surface. Owns one piece of
/// state — the group's share link — and exposes one intent
/// (`mintFor`) to load or refresh it.
///
/// Re-entry is idempotent: `currentOrMint` returns the existing key
/// rather than stacking a new one per visit.
///
/// Mirrors onym-android's `ShareInviteViewModel.kt`.
@MainActor
@Observable
public final class ShareInviteFlow: Identifiable {
    public enum State: Equatable, Sendable {
        case idle
        case minting
        case ready(link: String, groupName: String?)
        case failed(reason: String)
    }

    /// One revokable invite. `label` is nil for a superseded shared
    /// key; the view supplies the localized name for that case.
    public struct InviteRow: Equatable, Identifiable, Sendable {
        public let introPublicKey: Data
        public let label: String?
        public let createdAt: Date

        public var id: Data { introPublicKey }
    }

    /// Drives `.sheet(item:)` from a single source of truth.
    /// `.sheet(isPresented:)` paired with a separate optional-flow
    /// `@State` raced on first present — the content closure read
    /// `nil` and rendered an empty sheet (#107).
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    public private(set) var state: State = .idle

    /// Other live invites: the per-invitee offer keys, plus any
    /// superseded shared key, so nothing is left unrevokable.
    public private(set) var otherInvites: [InviteRow] = []

    /// Set while a rotate is in flight so the UI can disable the
    /// button — rotating twice in a row would strand a live key.
    public private(set) var isRotating = false

    private let identity: IdentityRepository
    private let introducer: InviteIntroducer
    private let groupRepository: GroupRepository

    public init(
        identity: IdentityRepository,
        introducer: InviteIntroducer,
        groupRepository: GroupRepository
    ) {
        self.identity = identity
        self.introducer = introducer
        self.groupRepository = groupRepository
    }

    /// Resolve and surface the group's share link. Idempotent: re-entry
    /// returns the same link. One link, many joiners.
    ///
    /// If `groupID` does not resolve to a local group (race between
    /// persistence + navigation, or a stale deeplink back into share)
    /// the state flips to `.failed` so the UI can render a message +
    /// retry button without crashing.
    public func mintFor(groupID: String) {
        Task { await mintForAsync(groupID: groupID) }
    }

    private func mintForAsync(groupID: String) async {
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.id == groupID }) else {
            state = .failed(reason: "Group not found on this device")
            return
        }
        guard let activeID = await identity.currentSelectedID() else {
            state = .failed(reason: "No identity selected")
            return
        }
        state = .minting
        do {
            let cap = try await introducer.currentOrMint(
                ownerIdentityID: activeID,
                groupId: group.groupIDData,
                groupName: group.name
            )
            state = .ready(link: cap.toAppLink(), groupName: group.name)
            await refreshOtherInvites(ownerIdentityID: activeID, groupId: group.groupIDData)
        } catch {
            state = .failed(reason: "\(error)")
        }
    }

    /// Replace the shared link. Nobody holding the old one is told, so
    /// this is the "my link leaked" escape hatch.
    public func rotateLink(groupID: String) {
        Task { await rotateLinkAsync(groupID: groupID) }
    }

    private func rotateLinkAsync(groupID: String) async {
        // Set before the first await, or a double-tap clears both this
        // guard and `.disabled(flow.isRotating)` inside the window.
        guard !isRotating else { return }
        isRotating = true
        defer { isRotating = false }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.id == groupID }) else {
            state = .failed(reason: "Group not found on this device")
            return
        }
        guard let activeID = await identity.currentSelectedID() else {
            state = .failed(reason: "No identity selected")
            return
        }
        do {
            let cap = try await introducer.rotate(
                ownerIdentityID: activeID,
                groupId: group.groupIDData,
                groupName: group.name
            )
            state = .ready(link: cap.toAppLink(), groupName: group.name)
        } catch {
            state = .failed(reason: "\(error)")
        }
    }

    /// Retire one per-invitee offer key.
    public func revoke(_ row: InviteRow, groupID: String) {
        Task { await revokeAsync(row, groupID: groupID) }
    }

    private func revokeAsync(_ row: InviteRow, groupID: String) async {
        await introducer.revoke(introPublicKey: row.introPublicKey)
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.id == groupID }),
              let activeID = await identity.currentSelectedID()
        else { return }
        await refreshOtherInvites(ownerIdentityID: activeID, groupId: group.groupIDData)
    }

    private func refreshOtherInvites(ownerIdentityID: IdentityID, groupId: Data) async {
        let current = currentIntroPublicKey()
        // Everything but the link on screen. A shared key stranded by a
        // crash mid-rotate would otherwise be listed nowhere.
        otherInvites = await introducer
            .liveInvites(ownerIdentityID: ownerIdentityID, groupId: groupId)
            .filter { $0.introPublicKey != current }
            .map { entry in
                InviteRow(
                    introPublicKey: entry.introPublicKey,
                    label: entry.label,
                    createdAt: entry.createdAt
                )
            }
    }

    /// Intro pubkey behind the rendered link, so the list excludes it.
    private func currentIntroPublicKey() -> Data? {
        guard case .ready(let link, _) = state,
              let cap = IntroCapability.fromLink(link)
        else { return nil }
        return cap.introPublicKey
    }
}
