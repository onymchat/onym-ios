import Foundation
import OnymBackup
import OnymBackupUI
import OnymBilling
import OnymChatsCore
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
            let stored = try? stateStore.load()
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
                displayName: BackupSeat.displayName(
                    componentId: enrolment.manifest.componentId, consentStore: consentStore),
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
                            && mediaPolicy == .descriptorsOnly
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
            )
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
                        otherOperators: stacks
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
        guard
            let stored = try? stack.stateStore.load(),
            stored.acceptedTermsId != nil
        else {
            return nil
        }
        let jurisdictions = stored.acceptedTermsRaw
            .flatMap { try? BackupTerms.decode(raw: $0) }?
            .jurisdictions ?? []
        return BackupDisclosure.OtherOperator(
            name: stack.displayName, jurisdictions: jurisdictions)
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
