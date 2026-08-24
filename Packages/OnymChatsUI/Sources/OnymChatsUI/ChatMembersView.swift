import SwiftUI
import OnymDesign
import OnymIdentity
import OnymGroup

/// Member roster for one chat. Drilled into from a `ChatsRow` tap.
/// Reads the latest `ChatGroup` from `ChatsFlow` by ID so the view
/// re-renders when an admin's PR-5 fanout lands a new joiner via
/// the receive-side dispatcher (PR 6).
///
/// Rendering rules:
/// - Sort by alias case-insensitively; entries with empty aliases
///   sink to the bottom under their BLS-pubkey fingerprint.
/// - Always show the BLS-pubkey hex prefix as a fingerprint —
///   aliases are self-asserted (per `MemberProfile`'s trust note),
///   so the fingerprint is the load-bearing identifier.
/// - "(you)" badge on the entry whose BLS pubkey hex matches the
///   currently-active identity — passed in via `IdentitiesFlow`
///   so a switch flips the badge without reopening the view.
/// - Empty state when the directory hasn't filled in yet (e.g.
///   joiner-side V1, where local materialization hasn't shipped
///   so `memberProfiles` is `[:]`).
struct ChatMembersView: View {
    let groupID: String
    @Bindable var chatsFlow: ChatsFlow
    @Bindable var identitiesFlow: IdentitiesFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let setGroupAvatar: @MainActor (String, Data?) async -> Void
    let setGroupName: @MainActor (String, String) async -> Void

    /// Both sheets present from this screen through one `sheet(item:)`
    /// over one enum — the rule `GateCheckRequiredView` already
    /// established here: two `.sheet` modifiers on the same view and
    /// SwiftUI has a long history of honouring only one of them. The
    /// admin's share-invite sheet would have been the silent casualty,
    /// and the harder one to notice, since only admins reach it.
    private enum ActiveSheet: Identifiable {
        case member(MemberRow)
        case shareInvite(ShareInviteFlow)

        var id: String {
            switch self {
            case .member(let row): "member:\(row.id)"
            case .shareInvite(let flow): "share:\(flow.id)"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    /// Standings, derived once per group snapshot rather than per
    /// render — and on demand, rather than one frame late.
    ///
    /// Each one is an Ed25519 verify plus a SHA-256, and this body
    /// re-renders off the group stream and on every keystroke in the
    /// rename alert. Measured on the simulator: 1.36 ms for 32 members,
    /// 9.35 ms for 256 — over half a frame, on the main actor, for an
    /// answer that cannot have changed in between.
    ///
    /// A memo rather than `onChange(initial: true)`, which fires *after*
    /// the first body evaluation: the roster's first frame drew every
    /// row unmarked and unchevroned, then re-rendered. Keyed on
    /// `ChatGroup.rulesStandingInputs` — everything the derivation
    /// reads and nothing else, declared next to it.
    @State private var memo = StandingsMemo()
    /// Drives the admin-only rename alert.
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        Group {
            if let group = currentGroup {
                VStack(spacing: 0) {
                    header(for: group)
                    // One scroll view over both, rather than the rules
                    // above it. They belong to the group and not to the
                    // roster — so they show even when the directory
                    // hasn't filled in — but `GroupRules.maxBytes`
                    // allows about forty lines, and hoisting them out
                    // of the scroll view made long rules unscrollable
                    // *and* squeezed the roster to nothing. Neither
                    // reachable is worse than the problem it fixed.
                    ScrollView {
                        VStack(spacing: 0) {
                            if let rules = GroupRules.normalized(group.invitationMessage) {
                                rulesSection(rules)
                            }
                            if group.memberProfiles.isEmpty {
                                emptyState
                            } else {
                                roster(for: group)
                            }
                        }
                    }
                }
            } else {
                missingGroupState
            }
        }
        .navigationTitle(currentGroup?.name ?? "Members")
        .navigationBarTitleDisplayMode(.inline)
        .background(OnymTokens.bg)
        .toolbar {
            // Only the cryptographic admin can mint a useful invite
            // link — non-admin members minting invites would surface
            // join requests in their own intro inbox, but the
            // approver's PR-13 anchor flow would short-circuit with
            // `.notAdminOfThisGroup` because they don't hold the
            // admin BLS secret. Hiding the entry-point removes the
            // footgun + matches the cryptographic constraint
            // already enforced on chain (sep-tyranny rejects
            // `update_commitment` proofs from non-admins).
            if canShareInvite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .shareInvite(makeShareInviteFlow())
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityLabel("Share invite link")
                    .accessibilityIdentifier("members.share_invite_button")
                }
            }
        }
        // Swept from here too, not only from the proof sheet: a user
        // who opens exactly one sheet and never another would otherwise
        // leave that member's rules and signature in plaintext until
        // the OS felt pressure. Any later visit to any group's member
        // list clears it.
        .task { await MemberRulesProofView.sweepStaleExports() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .member(let row):
                // Re-derived rather than memoized, unlike the roster:
                // one member's verify rather than a hundred, and
                // re-deriving is how the sheet stays correct against a
                // group that changes under it.
                //
                // Resolved from the live group at present time, not
                // from the row's captured profile: a roster update
                // while the sheet is open would otherwise leave a proof
                // rendered beside a group it no longer describes. The
                // fallback covers the group being deleted underneath —
                // an empty sheet is worse than one that says what
                // happened.
                if let group = currentGroup,
                   let proof = GroupRulesProof(group: group, blsHex: row.blsHex) {
                    MemberRulesProofView(proof: proof, onClose: { activeSheet = nil })
                } else {
                    MemberGoneView(onClose: { activeSheet = nil })
                }
            case .shareInvite(let flow):
                ShareInviteView(
                    groupID: groupID,
                    flow: flow,
                    onDone: { activeSheet = nil }
                )
            }
        }
        .alert("Rename group", isPresented: $showRename) {
            TextField("Group name", text: $renameText)
                .accessibilityIdentifier("members.rename_field")
            Button("Save") {
                let name = renameText
                Task { await setGroupName(groupID, name) }
            }
            .accessibilityIdentifier("members.rename_save")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in the group will see the new name.")
        }
    }

    // MARK: - State

    private var currentGroup: ChatGroup? {
        chatsFlow.groups.first { $0.id == groupID }
    }

    /// True iff the active identity is the cryptographic admin of
    /// this group — i.e. their BLS pubkey hex matches
    /// `group.adminPubkeyHex`. Gates the "Share invite" toolbar
    /// entry-point.
    ///
    /// Why not `group.ownerIdentityID == activeID`? `ownerIdentityID`
    /// is per-device; for a joiner-side group materialized from an
    /// invitation, it gets stamped as the joiner's local identity
    /// (so the chats-list filter routes it to the right tab). That
    /// would falsely report "you own this" for every joiner — the
    /// stronger BLS-pubkey-matches-stored-admin check is the right
    /// one. For Anarchy / OneOnOne we hide regardless: anarchy
    /// admit ceremonies aren't wired in V1, OneOnOne is fixed
    /// 2-party.
    private var canShareInvite: Bool {
        guard
            let group = currentGroup,
            group.groupType == .tyranny,
            let activeID = identitiesFlow.currentID,
            let activeSummary = identitiesFlow.identities.first(where: { $0.id == activeID })
        else { return false }
        return group.isAdmin(blsPublicKey: activeSummary.blsPublicKey)
    }

    /// Whether to show the editable (picker) avatar vs a read-only one.
    /// Same gate as `canShareInvite`: only the Tyranny admin can change
    /// the photo, because only their broadcast passes the receiver-side
    /// admin-signature check. Anarchy / OneOnOne have no admin, so the
    /// photo stays as set at create time in this pass.
    private var canChangeAvatar: Bool { canShareInvite }

    /// Bridges the picker to the broadcaster: reads the live group photo,
    /// and on a pick/clear ships it via `setGroupAvatar` (which applies
    /// locally + fans out). The local store write flows back through
    /// `chatsFlow.groups`, so the `get` reflects the change on the next
    /// render without extra @State.
    private var avatarBinding: Binding<Data?> {
        Binding(
            get: { currentGroup?.avatarJPEG },
            set: { [groupID, setGroupAvatar] newValue in
                Task { await setGroupAvatar(groupID, newValue) }
            }
        )
    }

    private var activeBlsHex: String? {
        guard
            let id = identitiesFlow.currentID,
            let summary = identitiesFlow.identities.first(where: { $0.id == id })
        else { return nil }
        return summary.blsPublicKey
            .map { String(format: "%02x", $0) }
            .joined()
            .lowercased()
    }

    // MARK: - Subviews

    /// Group-photo hero. Editable picker for the admin; a plain
    /// photo-or-mark for everyone else.
    @ViewBuilder
    private func header(for group: ChatGroup) -> some View {
        VStack(spacing: 8) {
            Group {
                if canChangeAvatar {
                    GroupAvatarPickerButton(
                        imageData: avatarBinding,
                        size: 72,
                        accent: OnymAccent.blue.color,
                        conceptText: group.name
                    )
                } else {
                    OnymGroupAvatar(size: 72, imageData: group.avatarJPEG)
                }
            }
            // Group name. Admin can rename (pencil affordance); everyone
            // else sees it read-only.
            if canChangeName {
                Button {
                    renameText = group.name
                    showRename = true
                } label: {
                    HStack(spacing: 5) {
                        Text(group.name)
                            .font(OnymType.font(size: 18, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                            .onymLineLimit(1)
                        Image(systemName: "pencil")
                            .font(OnymType.font(size: 13, weight: .semibold))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("members.rename_button")
            } else {
                Text(group.name)
                    .font(OnymType.font(size: 18, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                    .onymLineLimit(1)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Same admin gate as the avatar: only the Tyranny admin can rename,
    /// because only their broadcast passes the receiver's admin check.
    private var canChangeName: Bool { canShareInvite }

    /// The roster itself. No `ScrollView` of its own — the caller owns
    /// the one that has to contain the rules as well.
    private func roster(for group: ChatGroup) -> some View {
        Group {
            let memberRows = rows(for: group)
            VStack(spacing: 0) {
                ForEach(memberRows) { row in
                    memberRow(row)
                    // Computed once above rather than per iteration.
                    // `rows(for:)` runs an Ed25519 verify per member,
                    // and re-deriving it inside the loop made that
                    // quadratic — a hundred-member group meant ten
                    // thousand verifications per render.
                    if row.id != memberRows.last?.id {
                        Divider()
                            .background(OnymTokens.hairline)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(OnymTokens.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: OnymRadius.inset)
                    .stroke(OnymTokens.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text("\(group.memberProfiles.count) member\(group.memberProfiles.count == 1 ? "" : "s")")
                .font(OnymType.font(size: 12))
                .foregroundStyle(OnymTokens.text3)
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
    }

    /// The group's rules, shown to everyone rather than only to the
    /// people still deciding whether to join.
    ///
    /// A member who agreed months ago has no other way back to the
    /// words they agreed to — the confirmation screen is long gone, and
    /// until now the text lived only in an invitation nobody keeps.
    private func rulesSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GROUP RULES")
                .font(OnymType.font(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
                .padding(.leading, 4)
            Text(message)
                .font(OnymType.font(size: 15))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(14)
                .background(OnymTokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: OnymRadius.inset).stroke(OnymTokens.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
                .accessibilityIdentifier("members.rules")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func memberRow(_ row: MemberRow) -> some View {
        let mark = GroupRulesMark(row.standing)
        let content = HStack(spacing: 12) {
            avatar(for: row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayAlias)
                        .font(OnymType.font(size: 15, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    if row.isSelf {
                        Text("(you)")
                            .font(OnymType.font(size: 12))
                            .foregroundStyle(OnymTokens.text2)
                    }
                }
                // The fingerprint stays. It is the load-bearing
                // identifier — aliases are self-asserted, so two
                // members calling themselves the same thing are told
                // apart by this and nothing else — and the standing is
                // a second line rather than a replacement for it.
                Text("BLS \(row.blsPrefix)\u{2026}")
                    .font(OnymType.mono(size: 12))
                    .foregroundStyle(OnymTokens.text3)
                if let mark {
                    HStack(spacing: 4) {
                        Image(systemName: mark.symbol)
                            .font(OnymType.font(size: 10, weight: .semibold))
                        Text(mark.text)
                            .font(OnymType.font(size: 12))
                    }
                    .foregroundStyle(mark.color)
                }
            }
            Spacer(minLength: 0)
            // Gated on the mark, not on one standing: `GroupRulesMark`
            // is nil for `.notCollected` too, and such a row was
            // getting a chevron onto a sheet with no verdict, no
            // headline and an Export button for a group that collects
            // nothing — the dead end this rule was written to avoid.
            if row.standing.hasSomethingToShow {
                Image(systemName: "chevron.right")
                    .font(OnymType.font(size: 12, weight: .semibold))
                    .foregroundStyle(OnymTokens.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())

        return Group {
            if !row.standing.hasSomethingToShow {
                content
                    .accessibilityIdentifier("members.row.\(row.id)")
            } else {
                // On the button, not on the `Group` wrapping it: the
                // button is the accessibility element now that rows are
                // tappable, and an identifier on the container is one a
                // UI test may never see.
                Button { activeSheet = .member(row) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("members.row.\(row.id)")
            }
        }
    }

    private func avatar(for row: MemberRow) -> some View {
        let initial = row.displayAlias.first.map(String.init)?.uppercased() ?? "?"
        return ZStack {
            Circle()
                .fill(OnymAccent.blue.color.opacity(row.isSelf ? 1.0 : 0.6))
                .frame(width: 36, height: 36)
            Text(initial)
                .font(OnymType.font(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.onAccent)
        }
    }

    /// Sized rather than expanded: inside a scroll view a `Spacer`
    /// collapses, so this reserves its own height instead of claiming
    /// what is left of the screen.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(OnymType.font(size: 40))
                .foregroundStyle(OnymTokens.text3)
            Text("No members yet")
                .font(OnymType.font(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("Invite people from the chat to see them here.")
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.top, 24)
        .accessibilityIdentifier("members.empty")
    }

    private var missingGroupState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(OnymType.font(size: 40))
                .foregroundStyle(OnymTokens.text3)
            Text("Group not found")
                .font(OnymType.font(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("members.missing")
    }

    // MARK: - Row construction

    private func rows(for group: ChatGroup) -> [MemberRow] {
        let activeKey = activeBlsHex
        let standings = memo.standings(for: group)
        // Built from the memo's entries rather than from the profiles,
        // so a row's standing is never defaulted. The two are derived
        // from one snapshot, so a missing profile can't happen — and if
        // it ever did, dropping a row is honest where `.noRules` would
        // have quietly mislabelled a member.
        return standings
            .compactMap { (key, standing) -> MemberRow? in
                guard let profile = group.memberProfiles[key] else { return nil }
                return MemberRow(
                    id: key,
                    blsHex: key,
                    blsPrefix: String(key.prefix(12)),
                    displayAlias: profile.alias.isEmpty ? "(unnamed)" : profile.alias,
                    isSelf: activeKey.map { $0 == key } ?? false,
                    standing: standing
                )
            }
            .sorted { lhs, rhs in
                // Self always first, then alias case-insensitively,
                // then the fingerprint.
                //
                // The last one isn't decoration: aliases are
                // self-asserted and non-unique, the memo re-derives on
                // every group change, and a dictionary hands its
                // entries back in no particular order — so two members
                // sharing a name could swap places under a thumb
                // already moving toward a row that now opens somebody
                // else's agreement.
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                let byAlias = lhs.displayAlias.localizedCaseInsensitiveCompare(rhs.displayAlias)
                if byAlias != .orderedSame { return byAlias == .orderedAscending }
                return lhs.blsHex < rhs.blsHex
            }
    }

    private struct MemberRow: Identifiable {
        let id: String
        let blsHex: String
        let blsPrefix: String
        let displayAlias: String
        let isSelf: Bool
        /// Derived from the stored signature rather than read from a
        /// flag — once per group snapshot, via `StandingsMemo`.
        let standing: GroupRulesStanding
    }
}

/// One group snapshot's standings, computed the first time they are
/// asked for and kept until the snapshot changes.
///
/// A reference type held in `@State` on purpose: the view needs to fill
/// this during `body`, which rules out mutating `@State` value storage,
/// and it must not trigger an invalidation of its own — the result is a
/// pure function of the group already being rendered.
///
/// Keyed on `rulesStandingInputs` rather than the whole group: the
/// latter was correct, but it byte-compared `avatarJPEG` on every body
/// evaluation and retained a second copy of it for the screen's life.
/// The key is declared beside `rulesStanding` so the two can't drift.
@MainActor
final class StandingsMemo {
    private var snapshot: ChatGroup.RulesStandingInputs?
    private var cached: [String: GroupRulesStanding] = [:]

    /// Non-optional per key, so a caller can't fall back to an
    /// unmarked row and call that a standing.
    func standings(for group: ChatGroup) -> [String: GroupRulesStanding] {
        let inputs = group.rulesStandingInputs
        if snapshot == inputs { return cached }
        cached = group.memberProfiles.keys.reduce(into: [:]) { out, key in
            // The key came from `memberProfiles`, so the lookup cannot
            // miss; `.noRules` here would be a lie about a member
            // rather than a fallback.
            out[key] = group.rulesStanding(ofMemberWith: key) ?? .noRules
        }
        snapshot = inputs
        return cached
    }
}
