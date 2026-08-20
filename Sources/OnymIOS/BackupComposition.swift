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

    func makeDeviceBackupView() async -> DeviceBackupSettingsView? {
        guard let manifest = BackupSeat.consentedManifest(consentStore: consentStore) else {
            return nil
        }
        guard
            let material = try? await BackupKeys.material(
                deriving: identities, componentId: manifest.componentId),
            let workingDirectory = try? BackupSeat.workingDirectory()
        else {
            // No recovery phrase, or nowhere to write. Either way a
            // snapshot sealed now could not be opened later, and
            // offering the screen would be offering something false.
            return nil
        }

        let stateStore = FileBackupStateStore(
            url: workingDirectory.appending(path: "state.json"))
        let mediaPolicy = (try? stateStore.load())?.mediaPolicy ?? .descriptorsOnly

        let client = URLSessionBackupClient(
            manifest: manifest,
            material: material,
            endpointOverride: endpointOverride,
            entitlement: Self.entitlementProvider(
                manifest: manifest, store: entitlementStore, keys: seatKeys)
        )
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
        let repository = BackupRepository(
            port: client,
            composer: composer,
            stateStore: stateStore,
            keyMaterial: material
        )
        let consented = manifest.componentId
        let flow = DeviceBackupSettingsFlow(
            repository: repository,
            stateStore: stateStore,
            // Lets the flow tell "enrolled" from "enrolled with somebody
            // else", which is the difference between a working backup
            // and one that silently never uploads again.
            currentComponentId: { consented }
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

        return DeviceBackupSettingsView(flow: flow) {
            // The consent surface, reachable. Without this the section
            // rendered a status card with no way to turn backup on, and
            // everything behind it was unreachable code.
            BackupEnrolmentView(
                flow: BackupEnrolmentFlow(
                    port: client,
                    stateStore: stateStore,
                    workingDirectory: workingDirectory,
                    mediaPolicy: mediaPolicy)
            ) {
                flow.refresh()
            }
        } makeRestore: {
            // Reachable from the moment backup is set up. Building it
            // here rather than leaving a `nil` factory is deliberate:
            // every unreachable screen in this stack has been a screen
            // someone believed shipped.
            BackupRestoreView(
                flow: BackupRestoreFlow(
                    repository: repository,
                    restorer: restorer,
                    keyMaterial: material,
                    workingDirectory: workingDirectory))
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
