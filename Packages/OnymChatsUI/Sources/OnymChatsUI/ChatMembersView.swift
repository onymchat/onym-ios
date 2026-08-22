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

    @State private var shareInviteFlow: ShareInviteFlow?
    /// Drives the admin-only rename alert.
    @State private var showRename = false
    @State private var renameText = ""
    /// The member whose agreement is being looked at. Also the sheet's
    /// presentation state — one member at a time, by construction.
    @State private var selectedMember: MemberRow?

    var body: some View {
        Group {
            if let group = currentGroup {
                VStack(spacing: 0) {
                    header(for: group)
                    if group.memberProfiles.isEmpty {
                        emptyState
                    } else {
                        list(for: group)
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
                        shareInviteFlow = makeShareInviteFlow()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityLabel("Share invite link")
                    .accessibilityIdentifier("members.share_invite_button")
                }
            }
        }
        .sheet(item: $selectedMember) { row in
            // Resolved from the live group at present time, not from
            // the row's captured profile: a roster update while the
            // sheet is open would otherwise leave a proof rendered
            // beside a group it no longer describes. `nil` covers the
            // group being deleted underneath — an empty sheet is worse
            // than one that says what happened.
            if let group = currentGroup,
               let proof = GroupRulesProof(group: group, blsHex: row.blsHex) {
                MemberRulesProofView(proof: proof, onClose: { selectedMember = nil })
            } else {
                MemberGoneView(onClose: { selectedMember = nil })
            }
        }
        .sheet(item: $shareInviteFlow) { flow in
            ShareInviteView(
                groupID: groupID,
                flow: flow,
                onDone: { shareInviteFlow = nil }
            )
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
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("members.rename_button")
            } else {
                Text(group.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                    .lineLimit(1)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Same admin gate as the avatar: only the Tyranny admin can rename,
    /// because only their broadcast passes the receiver's admin check.
    private var canChangeName: Bool { canShareInvite }

    private func list(for group: ChatGroup) -> some View {
        ScrollView {
            if let rules = GroupRules.normalized(group.invitationMessage) {
                rulesSection(rules)
            }
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
                RoundedRectangle(cornerRadius: 12)
                    .stroke(OnymTokens.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text("\(group.memberProfiles.count) member\(group.memberProfiles.count == 1 ? "" : "s")")
                .font(.system(size: 12))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
                .padding(.leading, 4)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(14)
                .background(OnymTokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(OnymTokens.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("members.rules")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func memberRow(_ row: MemberRow) -> some View {
        let content = HStack(spacing: 12) {
            avatar(for: row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayAlias)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    if row.isSelf {
                        Text("(you)")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text2)
                    }
                }
                // The fingerprint stays. It is the load-bearing
                // identifier — aliases are self-asserted, so two
                // members calling themselves the same thing are told
                // apart by this and nothing else — and the standing is
                // a second line rather than a replacement for it.
                Text("BLS \(row.blsPrefix)\u{2026}")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(OnymTokens.text3)
                if let mark = Self.mark(for: row.standing) {
                    HStack(spacing: 4) {
                        Image(systemName: mark.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mark.text)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(mark.color)
                }
            }
            Spacer(minLength: 0)
            // Only where there is something to hand someone. A
            // chevron on a row whose sheet would say "nothing to show"
            // is an invitation to a dead end.
            if row.standing != .noRules {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnymTokens.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())

        return Group {
            if row.standing == .noRules {
                content
            } else {
                Button { selectedMember = row } label: { content }
                    .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("members.row.\(row.id)")
    }

    /// The mark beside a name. `nil` for a group with no rules, where
    /// the row keeps the BLS prefix it always showed — there is no
    /// standing to report, and "not applicable" on every row in every
    /// group without rules is noise.
    ///
    /// These are `ChatJoinRequestCell`'s own strings, not a matching
    /// set. A member's standing and a request's verdict are the same
    /// fact at two moments; near-duplicates would have given
    /// translators two of everything to drift apart.
    nonisolated static func mark(
        for standing: GroupRulesStanding
    ) -> (symbol: String, text: String, color: Color)? {
        switch standing {
        case .noRules:
            nil
        case .author:
            ("pencil", String(localized: "Wrote the group rules"), OnymTokens.text2)
        case .signed:
            ("checkmark.seal.fill",
             String(localized: "Signed the group rules"), OnymTokens.green)
        case .signedEarlierVersion:
            ("clock.badge.checkmark",
             String(localized: "Signed an earlier version of the rules"), OnymTokens.text2)
        case .didNotSign:
            ("minus.circle",
             String(localized: "Didn\u{2019}t sign the group rules"), OnymTokens.amber)
        case .unknownRules:
            ("questionmark.circle",
             String(localized: "Signed rules this device doesn\u{2019}t have \u{2014} can\u{2019}t be checked"),
             OnymTokens.text2)
        case .doesNotVerify:
            ("exclamationmark.triangle.fill",
             String(localized: "Their signature on the rules doesn\u{2019}t check out"), OnymTokens.red)
        }
    }

    private func avatar(for row: MemberRow) -> some View {
        let initial = row.displayAlias.first.map(String.init)?.uppercased() ?? "?"
        return ZStack {
            Circle()
                .fill(OnymAccent.blue.color.opacity(row.isSelf ? 1.0 : 0.6))
                .frame(width: 36, height: 36)
            Text(initial)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.onAccent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 40))
                .foregroundStyle(OnymTokens.text3)
            Text("No members yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("Invite people from the chat to see them here.")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("members.empty")
    }

    private var missingGroupState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(OnymTokens.text3)
            Text("Group not found")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("members.missing")
    }

    // MARK: - Row construction

    private func rows(for group: ChatGroup) -> [MemberRow] {
        let activeKey = activeBlsHex
        return group.memberProfiles
            .map { (key, profile) in
                MemberRow(
                    id: key,
                    blsHex: key,
                    blsPrefix: String(key.prefix(12)),
                    displayAlias: profile.alias.isEmpty ? "(unnamed)" : profile.alias,
                    isSelf: activeKey.map { $0 == key } ?? false,
                    standing: group.rulesStanding(ofMemberWith: key) ?? .noRules
                )
            }
            .sorted { lhs, rhs in
                // Self always first, then alias case-insensitively.
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                return lhs.displayAlias.localizedCaseInsensitiveCompare(rhs.displayAlias)
                    == .orderedAscending
            }
    }

    private struct MemberRow: Identifiable {
        let id: String
        let blsHex: String
        let blsPrefix: String
        let displayAlias: String
        let isSelf: Bool
        /// Re-derived on every render from the stored signature, not
        /// cached: see `GroupRulesStanding`.
        let standing: GroupRulesStanding
    }
}
