import Foundation
import Observation

/// Drives the post-create "Share invite" surface. Owns one piece of
/// state — the share link for the just-minted invite — and exposes
/// one intent (`mintFor`) to refresh / re-mint.
///
/// Why minting is decoupled from the view's first appearance:
/// minting is a side effect (writes to `IntroKeyStore`); doing it
/// in `.onAppear` ties it to view lifecycle (re-entries would mint
/// twice). This flow holds the side effect off the view tree where
/// it belongs. The view calls `mintFor` exactly once on appear,
/// re-mint requires an explicit "Generate new link" tap.
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

    /// Mint a fresh capability for the group with hex id `groupID` and
    /// surface the share link. Idempotent for repeated taps from the
    /// same screen — re-mints a fresh keypair so each share goes
    /// through a distinct intro slot (per-link revocation friendly).
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
            let cap = try await introducer.mint(
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
