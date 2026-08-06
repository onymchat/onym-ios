import Foundation
import Observation

/// Drives the post-create "Share invite" surface. Owns one piece of
/// state — the group's share link — and exposes one intent
/// (`mintFor`) to load or refresh it.
///
/// Why resolving the link is decoupled from the view's first
/// appearance: it touches `IntroKeyStore`, and doing that in
/// `.onAppear` ties a store write to view lifecycle. This flow holds
/// the side effect off the view tree where it belongs.
///
/// Re-entry is cheap and idempotent — invite links are multi-use, so
/// `InviteIntroducer.currentOrMint` hands back the group's existing
/// live key instead of stacking a new one per visit.
///
/// Mirrors onym-android's `ShareInviteViewModel.kt`.
@MainActor
@Observable
final class ShareInviteFlow: Identifiable {
    enum State: Equatable, Sendable {
        case idle
        case minting
        case ready(link: String, groupName: String?)
        case failed(reason: String)
    }

    /// One revokable invite on the list. `introPublicKey` is the
    /// revoke handle; it never reaches the screen.
    struct InviteRow: Equatable, Identifiable, Sendable {
        let introPublicKey: Data
        let label: String
        let createdAt: Date

        var id: Data { introPublicKey }
    }

    /// Drives `.sheet(item:)` from a single source of truth.
    /// `.sheet(isPresented:)` paired with a separate optional-flow
    /// `@State` raced on first present — the content closure read
    /// `nil` and rendered an empty sheet (#107).
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    private(set) var state: State = .idle

    /// Other live invites for this group — the create-time offer keys,
    /// each aimed at one invitee. The group's shared link is `state`,
    /// not a row here. Empty for a group created without invitees.
    ///
    /// Nothing expires any more, so this list is the only way these
    /// ever get retired.
    private(set) var otherInvites: [InviteRow] = []

    /// Set while a rotate is in flight so the UI can disable the
    /// button — rotating twice in a row would strand a live key.
    private(set) var isRotating = false

    private let identity: IdentityRepository
    private let introducer: InviteIntroducer
    private let groupRepository: GroupRepository

    init(
        identity: IdentityRepository,
        introducer: InviteIntroducer,
        groupRepository: GroupRepository
    ) {
        self.identity = identity
        self.introducer = introducer
        self.groupRepository = groupRepository
    }

    /// Resolve the share link for the group with hex id `groupID` and
    /// surface it. Idempotent: repeated calls (screen re-entry, Retry
    /// tap) return the *same* link while the group's intro key is
    /// inside its 24h `IntroKeyEntry.lifetime`, and only mint a fresh
    /// keypair once that key has expired. One link, many joiners.
    ///
    /// If `groupID` does not resolve to a local group (race between
    /// persistence + navigation, or a stale deeplink back into share)
    /// the state flips to `.failed` so the UI can render a message +
    /// retry button without crashing.
    func mintFor(groupID: String) {
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

    /// Replace the group's shared link. The old one stops working the
    /// moment the intro pump drops its subscription — there is no way
    /// to notify anyone already holding it, so this is the "my link
    /// leaked" escape hatch, not a polite hand-off.
    func rotateLink(groupID: String) {
        Task { await rotateLinkAsync(groupID: groupID) }
    }

    private func rotateLinkAsync(groupID: String) async {
        guard !isRotating else { return }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.id == groupID }) else {
            state = .failed(reason: "Group not found on this device")
            return
        }
        guard let activeID = await identity.currentSelectedID() else {
            state = .failed(reason: "No identity selected")
            return
        }
        isRotating = true
        defer { isRotating = false }
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
    func revoke(_ row: InviteRow, groupID: String) {
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
        // `label == nil` is the group's shared link, which the screen
        // already renders as the QR + link; only the named per-invitee
        // offers belong on the list.
        otherInvites = await introducer
            .liveInvites(ownerIdentityID: ownerIdentityID, groupId: groupId)
            .compactMap { entry in
                guard let label = entry.label else { return nil }
                return InviteRow(
                    introPublicKey: entry.introPublicKey,
                    label: label,
                    createdAt: entry.createdAt
                )
            }
    }
}
