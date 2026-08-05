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

    /// Drives `.sheet(item:)` from a single source of truth.
    /// `.sheet(isPresented:)` paired with a separate optional-flow
    /// `@State` raced on first present — the content closure read
    /// `nil` and rendered an empty sheet (#107).
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    private(set) var state: State = .idle

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
        } catch {
            state = .failed(reason: "\(error)")
        }
    }
}
