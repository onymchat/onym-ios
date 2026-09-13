import Foundation
import OnymGroup
import OnymIdentity
import OnymStellar
import OnymTransport
import OnymFoundation

/// Fans treasury payloads out to every member's inbox, sealed per
/// recipient — the same best-effort broadcast shape as
/// `GroupAvatarBroadcaster`, and for the same reason: there is no group
/// channel, only a set of inboxes.
///
/// Best-effort is deliberate. The local change is persisted first, so
/// the user sees it even if every send fails, and a member who misses a
/// payload is not stranded: a missed declaration re-arrives when its
/// author re-declares, and a missed proposal is visible to anyone who
/// opens the treasury screen, because the chain is the shared record
/// and this is only the notification.
public actor TreasuryBroadcaster {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport
    private let groups: GroupRepository
    private let treasury: TreasuryRepository

    public init(
        identity: IdentityRepository,
        inboxTransport: any InboxTransport,
        groups: GroupRepository,
        treasury: TreasuryRepository
    ) {
        self.identity = identity
        self.inboxTransport = inboxTransport
        self.groups = groups
        self.treasury = treasury
    }

    /// Declare which Stellar account should be this identity's
    /// co-signer in `groupIDHex`, and tell the group.
    ///
    /// The signature is made over
    /// `TreasurySignerDeclaration.statement(…)` with the identity's
    /// *identity* key — not the treasury key. The declaration is a
    /// claim by the Onym member ("this account is mine to sign with"),
    /// and it has to be checkable against the key the group already
    /// knows them by. For an external account it is the only key
    /// available, and for an Onym-derived one the treasury key's role
    /// is to sign transactions, not to introduce itself.
    @discardableResult
    public func declareSigner(
        groupIDHex: String,
        account: StellarAccountID,
        source: TreasurySignerSource,
        now: Date = Date()
    ) async -> Bool {
        guard let group = await group(groupIDHex),
              let me = await identity.currentIdentity(),
              let owner = await identity.currentSelectedID()
        else { return false }

        let statement = TreasurySignerDeclaration.statement(
            groupID: group.groupIDData,
            signerAccount: account,
            declarerSendingPublicKey: me.stellarPublicKey
        )
        guard let signature = try? await identity.signWithStellarKey(statement) else {
            return false
        }
        let myBlsHex = me.blsPublicKey.hexString

        // Local first — the broadcast below is best-effort.
        await treasury.record(TreasurySignerDeclarationRecord(
            groupID: groupIDHex,
            ownerIdentityID: owner,
            memberBlsPubkeyHex: myBlsHex,
            account: account,
            source: source,
            signature: signature,
            declarerSendingPublicKey: me.stellarPublicKey,
            declaredAt: now
        ))

        await fanOut(
            TreasurySignerDeclarationPayload(
                groupID: group.groupIDData,
                declarerBlsPubkeyHex: myBlsHex,
                signerAccountID: account.accountID,
                source: source,
                sentAtMillis: Int64(now.timeIntervalSince1970 * 1000),
                signature: signature
            ),
            to: group,
            excludingSelf: myBlsHex
        )
        return true
    }

    /// Tell the group which account is now its treasury. Founder-side,
    /// after the creation transaction has applied.
    public func announceAnchor(_ anchored: Treasury, now: Date = Date()) async {
        guard let group = await group(anchored.groupID),
              let me = await identity.currentIdentity()
        else { return }
        await fanOut(
            TreasuryAnchorPayload(
                groupID: group.groupIDData,
                treasuryAccountID: anchored.account.accountID,
                networkPassphrase: anchored.network.passphrase,
                creationTxHash: anchored.creationTxHash,
                sentAtMillis: Int64(now.timeIntervalSince1970 * 1000)
            ),
            to: group,
            excludingSelf: me.blsPublicKey.hexString
        )
    }

    /// Put a transaction to the group.
    public func broadcast(_ proposal: TreasuryProposal, now: Date = Date()) async {
        guard let group = await group(proposal.groupID),
              let me = await identity.currentIdentity()
        else { return }
        await fanOut(
            TreasuryProposalPayload(
                groupID: group.groupIDData,
                proposalID: proposal.id,
                proposerBlsPubkeyHex: proposal.proposerBlsPubkeyHex,
                xdr: proposal.envelope.base64XDR,
                networkPassphrase: proposal.network.passphrase,
                sentAtMillis: Int64(now.timeIntervalSince1970 * 1000)
            ),
            to: group,
            excludingSelf: me.blsPublicKey.hexString
        )
    }

    /// Send one co-signer's signature to everyone, so whichever device
    /// is open when the threshold is reached can submit.
    public func broadcastSignature(
        proposal: TreasuryProposal,
        signature: Data,
        signer: StellarAccountID,
        now: Date = Date()
    ) async {
        guard let group = await group(proposal.groupID),
              let me = await identity.currentIdentity()
        else { return }
        await fanOut(
            TreasurySignaturePayload(
                groupID: group.groupIDData,
                proposalID: proposal.id,
                signerAccountID: signer.accountID,
                signature: signature,
                sentAtMillis: Int64(now.timeIntervalSince1970 * 1000)
            ),
            to: group,
            excludingSelf: me.blsPublicKey.hexString
        )
    }

    // MARK: - Fan-out

    /// Scoped to the owning identity.
    ///
    /// `currentGroups()` returns the unfiltered cache across every
    /// local identity, so with two identities in one group the roster
    /// fanned out to could come from the other identity's copy while
    /// the row is written under `currentSelectedID()`.
    private func group(_ groupIDHex: String) async -> ChatGroup? {
        guard let owner = await identity.currentSelectedID() else { return nil }
        return await groups.currentGroups().first {
            $0.id == groupIDHex && $0.ownerIdentityID == owner
        }
    }

    private func fanOut(
        _ payload: some Encodable,
        to group: ChatGroup,
        excludingSelf myBlsHex: String
    ) async {
        guard let bytes = try? JSONEncoder().encode(payload) else { return }
        for (memberKey, profile) in group.memberProfiles {
            // Skip self — the local change is already applied.
            if memberKey == myBlsHex.lowercased() { continue }
            guard let sealed = try? await identity.sealInvitation(
                payload: bytes,
                to: profile.inboxPublicKey
            ) else { continue }
            let tag = TransportInboxID(
                rawValue: IntroInboxPump.inboxTag(from: profile.inboxPublicKey)
            )
            // Receipt discarded: see the type's note on best-effort.
            _ = try? await inboxTransport.send(sealed, to: tag)
        }
    }
}
