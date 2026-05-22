import Foundation

/// Seam the dispatcher delegates Tyranny group-state verification to.
/// Two roles, because any device is both a potential invitee and a
/// potential admin:
///   - `deferVerification` (invitee): a snapshot couldn't be verified at
///     an exact epoch (chain advanced past it) — ask the admin for the
///     current state instead of materializing an unverifiable group.
///   - `handleRefreshRequest` (admin): reply to such a request with the
///     current snapshot, gated on the requester being a current member.
protocol GroupStateRefreshing: Sendable {
    func deferVerification(
        invitation: GroupInvitationPayload,
        ownerIdentityID: IdentityID
    ) async
    func handleRefreshRequest(
        _ request: GroupStateRefreshRequest,
        ownerIdentityID: IdentityID,
        requesterEd25519: Data?
    ) async
}

/// No-op conformer — the dispatcher's default so the many existing test
/// constructions don't have to thread a verifier they don't exercise.
struct NoopGroupStateRefresher: GroupStateRefreshing {
    func deferVerification(invitation: GroupInvitationPayload, ownerIdentityID: IdentityID) async {}
    func handleRefreshRequest(_ request: GroupStateRefreshRequest, ownerIdentityID: IdentityID, requesterEd25519: Data?) async {}
}

/// Drives the "verify at current state" leg of the converge-forward
/// design (Option 2). When an invitation snapshot is stale, the invitee
/// asks the admin for the current `(epoch, salt, members, commitment)`;
/// the admin replies with a fresh `GroupInvitationPayload` that verifies
/// at an exact epoch. If the admin can't be reached, the group is left
/// in a `.unreachable` pending state and surfaced to the user — never
/// silently materialized or dropped.
actor GroupStateVerifier: GroupStateRefreshing {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport
    private let groupRepository: GroupRepository
    private let store: PendingVerificationStore
    private let refreshTimeoutSeconds: UInt64

    /// Re-send targets, kept so an in-session Retry (and the timeout)
    /// can act without re-parsing the original snapshot. Cleared when
    /// the group materializes.
    private var targets: [String: RefreshTarget] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var watchTask: Task<Void, Never>?

    private struct RefreshTarget {
        let groupID: Data
        let adminInboxKey: Data
        let ownerIdentityID: IdentityID
    }

    init(
        identity: IdentityRepository,
        inboxTransport: any InboxTransport,
        groupRepository: GroupRepository,
        store: PendingVerificationStore,
        refreshTimeoutSeconds: UInt64 = 30
    ) {
        self.identity = identity
        self.inboxTransport = inboxTransport
        self.groupRepository = groupRepository
        self.store = store
        self.refreshTimeoutSeconds = refreshTimeoutSeconds
    }

    /// Watch the group repo so a pending verification is resolved (and
    /// its timeout cancelled) the moment the fresh snapshot materializes
    /// its group. Idempotent.
    func start() {
        watchTask?.cancel()
        let stream = groupRepository.snapshots
        watchTask = Task { [weak self] in
            for await groups in stream {
                guard let self else { return }
                await self.resolve(Set(groups.map(\.id)))
            }
        }
    }

    // MARK: - Invitee side

    func deferVerification(
        invitation: GroupInvitationPayload,
        ownerIdentityID: IdentityID
    ) async {
        let groupIDHex = Self.hex(invitation.groupID)
        guard await !store.contains(groupIDHex: groupIDHex) else { return }

        // We can only ask the admin if the snapshot told us their inbox.
        guard let adminBls = invitation.adminPubkeyHex?.lowercased(),
              let adminInbox = invitation.memberProfiles?[adminBls]?.inboxPublicKey
        else {
            await store.record(PendingGroupVerification(
                groupIDHex: groupIDHex,
                ownerIdentityID: ownerIdentityID,
                groupName: invitation.name,
                status: .unreachable,
                receivedAt: Date()
            ))
            return
        }

        await store.record(PendingGroupVerification(
            groupIDHex: groupIDHex,
            ownerIdentityID: ownerIdentityID,
            groupName: invitation.name,
            status: .verifying,
            receivedAt: Date()
        ))
        targets[groupIDHex] = RefreshTarget(
            groupID: invitation.groupID,
            adminInboxKey: adminInbox,
            ownerIdentityID: ownerIdentityID
        )
        await sendRefresh(groupIDHex: groupIDHex)
    }

    /// Re-send a refresh for a still-pending group (manual Retry, or an
    /// auto-retry on foreground). No-op if the group resolved or we have
    /// no target for it.
    func retry(groupIDHex: String) async {
        guard targets[groupIDHex] != nil else { return }
        await store.updateStatus(groupIDHex: groupIDHex, status: .verifying)
        await sendRefresh(groupIDHex: groupIDHex)
    }

    private func sendRefresh(groupIDHex: String) async {
        guard let target = targets[groupIDHex] else { return }
        // Build the request from the *current* identity. V1 assumes the
        // owner is the selected identity (matching the single-active
        // assumption elsewhere); if it isn't, the admin's membership
        // check simply won't match and we fall through to `.unreachable`.
        guard let me = await identity.currentIdentity(),
              let request = try? GroupStateRefreshRequest(
                  groupID: target.groupID,
                  requesterInboxPublicKey: me.inboxPublicKey,
                  requesterBlsPublicKey: me.blsPublicKey
              ),
              let bytes = try? JSONEncoder().encode(request),
              let sealed = try? await identity.sealInvitation(payload: bytes, to: target.adminInboxKey)
        else {
            await store.updateStatus(groupIDHex: groupIDHex, status: .unreachable)
            return
        }
        let tag = TransportInboxID(rawValue: IntroInboxPump.inboxTag(from: target.adminInboxKey))
        let receipt = try? await inboxTransport.send(sealed, to: tag)
        guard let receipt, receipt.acceptedBy >= 1 else {
            await store.updateStatus(groupIDHex: groupIDHex, status: .unreachable)
            return
        }
        scheduleTimeout(groupIDHex)
    }

    private func scheduleTimeout(_ groupIDHex: String) {
        timeouts[groupIDHex]?.cancel()
        let seconds = refreshTimeoutSeconds
        timeouts[groupIDHex] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.markUnreachableIfStillVerifying(groupIDHex)
        }
    }

    private func markUnreachableIfStillVerifying(_ groupIDHex: String) async {
        guard await store.contains(groupIDHex: groupIDHex) else { return }
        await store.updateStatus(groupIDHex: groupIDHex, status: .unreachable)
    }

    private func resolve(_ materializedHexes: Set<String>) async {
        let resolved = targets.keys.filter { materializedHexes.contains($0) }
        for hex in resolved {
            timeouts[hex]?.cancel()
            timeouts[hex] = nil
            targets[hex] = nil
        }
        await store.resolveMaterialized(materializedHexes)
    }

    // MARK: - Admin side

    func handleRefreshRequest(
        _ request: GroupStateRefreshRequest,
        ownerIdentityID: IdentityID,
        requesterEd25519: Data?
    ) async {
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.groupIDData == request.groupID && $0.ownerIdentityID == ownerIdentityID
        }) else {
            return
        }
        // Membership gate — the reply carries `salt`, so only answer a
        // requester that is a current member, and only after confirming
        // the envelope's signer matches that member's stored Ed25519
        // (insider-spoof defense). Sealing target is pinned to the
        // member's stored inbox key, not the request's claimed one, so a
        // forged request can't redirect the salt elsewhere.
        let key = Self.hex(request.requesterBlsPublicKey)
        guard let profile = group.memberProfiles[key] else { return }
        guard let requesterEd25519, requesterEd25519 == profile.sendingPubkey else { return }
        guard request.requesterInboxPublicKey == profile.inboxPublicKey else { return }

        let invite = GroupInvitationPayload(
            version: 1,
            groupID: group.groupIDData,
            groupSecret: group.groupSecret,
            name: group.name,
            members: group.members,
            epoch: group.epoch,
            salt: group.salt,
            commitment: group.commitment,
            tierRaw: group.tier.rawValue,
            groupTypeRaw: group.groupType.rawValue,
            adminPubkeyHex: group.adminPubkeyHex,
            memberProfiles: group.memberProfiles.isEmpty ? nil : group.memberProfiles
        )
        guard let bytes = try? JSONEncoder().encode(invite),
              let sealed = try? await identity.sealInvitation(
                  payload: bytes,
                  to: profile.inboxPublicKey
              )
        else { return }
        let tag = TransportInboxID(rawValue: IntroInboxPump.inboxTag(from: profile.inboxPublicKey))
        _ = try? await inboxTransport.send(sealed, to: tag)
    }

    // MARK: - Helpers

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
