import Foundation
import OnymBackup
import OnymBackupUI
import OnymBilling
import OnymChatsCore
import OnymDiscovery
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymPersistence
import OnymTransportBlossom

/// Builds the device-backup screen, or returns `nil` when there is
/// nothing to build.
///
/// `nil` happens for ordinary reasons: no backup operator consented to,
/// or an identity imported from raw key material and therefore without a
/// recovery phrase to derive a key from. Both mean the Settings section
/// hides rather than offering something that cannot work.
///
/// A person may keep the same history with more than one operator, so
/// this assembles one stack per consented operator and one fan-out over
/// all of them. What is shared is the part that is a property of the
/// identity: the source of truth being read, and the archive key ladder,
/// which comes from the recovery seed alone so that a snapshot is
/// openable by whoever holds the phrase rather than by whoever stored
/// it. Everything else — the access keys, the terms pin, the chain, the
/// entitlement, the local state file — is per operator, because
/// `UI-Backup.md` §14.12 says one operator never receives another's.
@MainActor
struct BackupSeatComposer {
    let identities: IdentityRepository
    let groupStore: any GroupStore
    let messageStore: any MessageStore
    let invitationStore: any InvitationStore
    let consentStore: any PinnedConsentStore
    let blobClient: (any BlossomClient)?
    /// DEBUG override for a local operator, via `--backup-base-url`.
    let endpointOverride: URL?
    /// Purchased credentials. Presented to an operator that declares
    /// entitlement issuers; an operator that declares none never sees a
    /// credential and never asks for one.
    let entitlementStore: (any SeatEntitlementStoring)?
    let seatKeys: any SeatAccessKeyProviding
    /// Recovers a credential for a purchase made on another device.
    /// `nil` when this build cannot sell anything, in which case the
    /// screen offers no restore-purchases row rather than one that
    /// always reports nothing.
    let makePurchaseFlow: (@Sendable (String) async -> SeatPurchaseFlow?)?
    /// Whether this build can actually sell anything for an operator.
    /// A free operator declares no offers, and a build whose bundled
    /// catalog is missing sells nothing at all — in both cases a Restore
    /// Purchases row would prompt for an App Store password and then
    /// always answer "nothing to restore".
    let sellsOffers: (@Sendable (String) -> Bool)?

    /// One operator's assembled stack, before it becomes a screen.
    private struct Stack {
        let componentId: String
        let displayName: String
        /// What *this* operator was consented under, which is not
        /// necessarily what the shared archive ends up carrying.
        let consentedMediaPolicy: BackupMediaPolicy?
        let client: URLSessionBackupClient
        let stateStore: FileBackupStateStore
        let material: BackupKeyMaterial
        let repository: BackupRepository
    }

    func makeDeviceBackupView() async -> DeviceBackupVendorsView? {
        let manifests = BackupSeat.consentedManifests(consentStore: consentStore)
        guard !manifests.isEmpty, let workingDirectory = try? BackupSeat.workingDirectory() else {
            return nil
        }
        // A single-operator install kept its state in `state.json`.
        // Without moving it onto the per-operator path, this launch
        // would read no state for the operator the person is already
        // enrolled with: backup would show as off, and the next snapshot
        // would supersede nothing and be paid for twice.
        BackupVendorStorage.migrateLegacyState(in: workingDirectory)

        // Two passes, because the archive is composed once for every
        // operator and its media policy therefore has to be decided
        // before the composer exists.
        var enrolments: [(manifest: BackupOperatorManifest, stateStore: FileBackupStateStore,
                          material: BackupKeyMaterial, consentedMediaPolicy: BackupMediaPolicy?)] = []
        var policies: [BackupMediaPolicy] = []
        for manifest in manifests {
            guard
                let material = try? await BackupKeys.material(
                    deriving: identities, componentId: manifest.componentId)
            else {
                // No recovery phrase. A snapshot sealed now could not be
                // opened later, and that is true at every operator, so
                // there is nothing to build at all.
                return nil
            }
            let stateStore = BackupVendorStorage.stateStore(
                componentId: manifest.componentId, in: workingDirectory)
            // `try?` would be wrong here in the one direction that
            // matters. An unreadable state file — a corrupt one, or one
            // read while the device is locked and the container is under
            // complete protection — would drop this operator's policy
            // from the vote, and the vote is unanimity: with its
            // descriptors-only vote missing, a single includeCiphertext
            // operator carries it, and attachments go to an operator the
            // person never agreed to give them to. So an unreadable
            // state votes for the strictest policy, which is what
            // `FileBackupStateStore` throwing rather than returning an
            // empty state is for.
            let stored: BackupState?
            do {
                stored = try stateStore.load()
            } catch {
                stored = nil
                policies.append(.descriptorsOnly)
            }
            let consented = stored?.acceptedTermsId == nil ? nil : stored?.mediaPolicy
            if let consented { policies.append(consented) }
            enrolments.append((manifest, stateStore, material, consented))
        }
        guard let first = enrolments.first else { return nil }

        // The strictest policy any enrolled operator was consented under
        // wins, because one archive is composed for all of them. The
        // other direction would send an operator attachments the person
        // agreed to give somebody else — a widening of the eligible set
        // by composition order, and §14.10 says the eligible set never
        // widens without an explicit choice.
        let mediaPolicy: BackupMediaPolicy =
            !policies.isEmpty && policies.allSatisfy { $0 == .includeCiphertext }
                ? .includeCiphertext
                : .descriptorsOnly

        let composer = BackupComposer(
            source: AppBackupSource(
                groupStore: groupStore,
                messageStore: messageStore,
                invitationStore: invitationStore,
                consentStore: consentStore,
                blobClient: mediaPolicy == .includeCiphertext ? blobClient : nil
            ),
            mediaPolicy: mediaPolicy,
            workingDirectory: workingDirectory
        )

        // An operator's name is a string it wrote in its own manifest,
        // and nothing stops two of them writing the same one. That
        // string is the only thing telling operators apart on every
        // surface here — the rows, the restore list, the unreachable
        // note, and the "you already back up to X" sentence someone
        // reads while consenting to a *different* X. Pinning stops an
        // operator relabelling itself after consent; it does not stop it
        // colliding at consent time.
        let displayNames = Self.distinctDisplayNames(
            for: enrolments.map(\.manifest.componentId), consentStore: consentStore)

        let stacks: [Stack] = enrolments.map { enrolment in
            let client = URLSessionBackupClient(
                manifest: enrolment.manifest,
                material: enrolment.material,
                endpointOverride: endpointOverride,
                entitlement: Self.entitlementProvider(
                    manifest: enrolment.manifest, store: entitlementStore, keys: seatKeys)
            )
            return Stack(
                componentId: enrolment.manifest.componentId,
                displayName: displayNames[enrolment.manifest.componentId]
                    ?? enrolment.manifest.componentId,
                consentedMediaPolicy: enrolment.consentedMediaPolicy,
                client: client,
                stateStore: enrolment.stateStore,
                material: enrolment.material,
                repository: BackupRepository(
                    port: client,
                    composer: composer,
                    stateStore: enrolment.stateStore,
                    keyMaterial: enrolment.material
                )
            )
        }

        let flow = DeviceBackupVendorsFlow(
            vendors: stacks.map {
                DeviceBackupVendorsFlow.Vendor(
                    flow: DeviceBackupSettingsFlow(
                        componentId: $0.componentId,
                        displayName: $0.displayName,
                        repository: $0.repository,
                        stateStore: $0.stateStore,
                        // Consented to with media, and not getting it,
                        // because somebody else was not.
                        attachmentsWithheld: $0.consentedMediaPolicy == .includeCiphertext
                            && mediaPolicy == .descriptorsOnly,
                        onStopBackingUp: Self.stopBackingUp(
                            componentId: $0.componentId, consentStore: consentStore)
                    )
                )
            },
            fanOut: BackupFanOut(
                vendors: stacks.map {
                    BackupFanOut.Vendor(
                        componentId: $0.componentId,
                        displayName: $0.displayName,
                        repository: $0.repository,
                        stateStore: $0.stateStore
                    )
                },
                composer: composer,
                // Identity-wide by derivation: `BackupKeys.archiveRootKey`
                // takes the seed and nothing else, so every operator's
                // material carries the same one. Taking it from the first
                // is not a choice about which operator is special.
                archiveRoot: first.material.archiveRoot
            ),
            restorePurchasesForOperator: stacks.contains(where: { sellsOffers?($0.componentId) == true })
                ? Self.purchaseRestorer(makePurchaseFlow)
                : nil,
            syncPurchasesWithStore: Self.storeSyncer(makePurchaseFlow, componentId: first.manifest.componentId)
        )

        // Restored attachment ciphertext, and the client that will
        // actually serve it. Writing bytes to a directory no loader
        // reads would let the summary report attachments "restored"
        // while every one of them still renders via network-or-nothing.
        let restoredBlobs = workingDirectory.appending(path: "blobs")
        let restorer = BackupRestorer(
            sink: AppBackupSink(
                groupStore: groupStore,
                messageStore: messageStore,
                invitationStore: invitationStore,
                consentStore: consentStore,
                blobDirectory: restoredBlobs))

        return DeviceBackupVendorsView(
            flow: flow,
            makeEnrolment: { componentId in
                guard let stack = stacks.first(where: { $0.componentId == componentId })
                else {
                    return nil
                }
                return BackupEnrolmentView(
                    flow: BackupEnrolmentFlow(
                        port: stack.client,
                        stateStore: stack.stateStore,
                        workingDirectory: workingDirectory,
                        mediaPolicy: mediaPolicy,
                        // Named so the surface can say what adding a
                        // second operator does rather than let it read
                        // as switching.
                        // Only when this operator is not already one of
                        // the copies. Re-reading an operator's new terms
                        // routes through this same screen, and it used
                        // to greet someone with "This adds a second copy
                        // — it does not move the first" for an operator
                        // that has been holding a copy for months.
                        otherOperators: Self.isEnrolled(stack)
                            ? []
                            : stacks
                                .filter { $0.componentId != componentId }
                                .compactMap(Self.otherOperator(from:))
                    )
                ) {
                    flow.refresh()
                }
            },
            makeRestore: {
                BackupRestoreView(
                    flow: BackupRestoreFlow(
                        sources: stacks.map {
                            BackupRestoreSource(
                                componentId: $0.componentId,
                                displayName: $0.displayName,
                                repository: $0.repository)
                        },
                        restorer: restorer,
                        // Opening a snapshot uses the archive root,
                        // which is the same for every operator; the
                        // per-operator access keys are inside each
                        // repository and are not used to decrypt
                        // anything.
                        keyMaterial: first.material,
                        workingDirectory: workingDirectory))
            }
        )
    }

    /// Names that tell the operators apart, whatever they call
    /// themselves.
    ///
    /// A collision falls back to the component id for *both* sides, not
    /// just the newcomer: disambiguating only one leaves the other
    /// wearing the plain name, which reads as the authentic one.
    @MainActor
    private static func distinctDisplayNames(
        for componentIds: [String],
        consentStore: any PinnedConsentStore
    ) -> [String: String] {
        var claimed: [String: [String]] = [:]
        for componentId in componentIds {
            let name = BackupSeat.displayName(componentId: componentId, consentStore: consentStore)
            claimed[name, default: []].append(componentId)
        }
        var resolved: [String: String] = [:]
        for (name, componentIds) in claimed {
            for componentId in componentIds {
                resolved[componentId] = componentIds.count == 1
                    ? name
                    : "\(name) (\(ModuleConsentFlow.shortComponentId(componentId)))"
            }
        }
        return resolved
    }

    /// Withdraw consent so this operator stops being part of the seat.
    ///
    /// The local state is already cleared by the flow; this is the other
    /// half, and without it the operator reappears in the list on the
    /// next visit to Settings — consented, unenrolled, and offering to
    /// be set up again.
    private static func stopBackingUp(
        componentId: String,
        consentStore: any PinnedConsentStore
    ) -> @MainActor @Sendable () -> Void {
        { @MainActor @Sendable in
            // A failed withdrawal is not reported here: the flow has
            // already cleared this device's state, so nothing is being
            // uploaded to this operator either way. The row returning
            // as "not set up" is the visible consequence, and setting
            // it up again is a screen.
            try? consentStore.withdraw(componentId: componentId)
        }
    }

    /// Whether this operator already holds a copy — that is, whether
    /// this enrolment is a first one or a re-reading of new terms.
    private static func isEnrolled(_ stack: Stack) -> Bool {
        (try? stack.stateStore.load())?.acceptedTermsId != nil
    }

    /// One already-enrolled operator, described only by what it signed.
    ///
    /// Its jurisdictions come from the terms bytes this device pinned
    /// when the person consented — `acceptedTermsRaw`, kept for exactly
    /// this kind of question — rather than from a fetch that could
    /// answer differently today. Returns `nil` for an operator that is
    /// not enrolled, which has no copy to speak of, and reports empty
    /// jurisdictions rather than guessing when the pinned bytes will not
    /// decode.
    private static func otherOperator(from stack: Stack) -> BackupDisclosure.OtherOperator? {
        let stored = try? stack.stateStore.load()
        // Only a state that loaded *and* says so is "not enrolled". An
        // unreadable one is named anyway, without jurisdictions: the
        // consequence of over-naming is a person told they may already
        // have a copy somewhere they do not, and the consequence of
        // under-naming is the whole "this adds a second copy" headline
        // silently disappearing from the consent screen — someone agrees
        // to a second copy of everyone's messages in a second
        // jurisdiction believing they are switching. This disclosure
        // fails loud.
        if let stored, stored.acceptedTermsId == nil { return nil }
        let jurisdictions = stored?.acceptedTermsRaw
            .flatMap { try? BackupTerms.decode(raw: $0) }?
            .jurisdictions ?? []
        return BackupDisclosure.OtherOperator(
            name: stack.displayName, jurisdictions: jurisdictions)
    }

    /// Turns the purchase-flow factory into the sweep the screen calls.
    ///
    /// Per operator, because a `SeatPurchaseFlow` pins the issuer key it
    /// will verify a broker's answer against, and that key comes from
    /// the operator's own signed manifest. There is no app-wide broker
    /// client, and a credential must not be able to nominate its own
    /// authority.
    private static func purchaseRestorer(
        _ makePurchaseFlow: (@Sendable (String) async -> SeatPurchaseFlow?)?
    ) -> (@Sendable (String) async -> SeatPurchaseFlow.RestoreResult?)? {
        guard let makePurchaseFlow else { return nil }
        return { @Sendable componentId in
            // `nil` means this operator was not checked — no pinned
            // issuer to verify a broker's answer against — which the
            // caller must not report as the App Store having nothing.
            guard let flow = await makePurchaseFlow(componentId) else { return nil }
            return await flow.restorePurchases(componentId: componentId)
        }
    }

    /// The account-wide sync, done once per tap.
    ///
    /// It needs a flow to reach StoreKit through, and any operator's
    /// will do: `AppStore.sync()` is a property of the Apple account,
    /// not of a seat. A sync failure is not a reason to skip the sweep
    /// that follows — `currentEntitlement` answers from what the device
    /// already knows, and that is usually everything needed.
    private static func storeSyncer(
        _ makePurchaseFlow: (@Sendable (String) async -> SeatPurchaseFlow?)?,
        componentId: String
    ) -> (@Sendable () async -> Void)? {
        guard let makePurchaseFlow else { return nil }
        return { @Sendable in
            guard let flow = await makePurchaseFlow(componentId) else { return }
            try? await flow.syncWithStore()
        }
    }

    /// The credential to present, chosen at request time.
    ///
    /// Read per request rather than captured once: a purchase completed
    /// while the screen is open should take effect on the next upload,
    /// not on the next launch. An operator that declares no issuers gets
    /// nothing — a free operator has no use for a credential.
    private static func entitlementProvider(
        manifest: BackupOperatorManifest,
        store: (any SeatEntitlementStoring)?,
        keys: any SeatAccessKeyProviding
    ) -> @Sendable () async -> Data? {
        let componentId = manifest.componentId
        let issuers = manifest.entitlementIssuers
        return { @Sendable in
            guard !issuers.isEmpty, let store else { return nil }
            guard
                let subject = try? await keys.seatSubject(componentId: componentId),
                let stored = try? store.load()
            else {
                return nil
            }
            let verifier = SeatEntitlementVerifier(
                trustedIssuers: issuers, componentId: componentId, subject: subject)
            for raw in stored {
                guard
                    let entitlement = try? SeatEntitlement.decode(raw: raw),
                    (try? verifier.verify(entitlement)) != nil
                else {
                    continue
                }
                return raw
            }
            // Nothing usable. Sending an expired or foreign credential
            // would earn `invalid_entitlement` where `payment_required`
            // is the honest answer, and the second one is what a person
            // can act on.
            return nil
        }
    }
}
