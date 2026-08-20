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
            entitlement: { nil }
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
        let flow = DeviceBackupSettingsFlow(
            repository: repository,
            stateStore: stateStore
        )
        return DeviceBackupSettingsView(flow: flow) { nil }
    }
}
