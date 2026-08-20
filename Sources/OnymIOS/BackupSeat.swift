import CryptoKit
import Foundation
import OnymBackup
import OnymBackupUI
import OnymBilling
import OnymChatsCore
import OnymDiscovery
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymModeration
import OnymPersistence
import OnymTransportBlossom

/// Assembles the device-backup seat from what the person has actually
/// chosen.
///
/// Nothing here decides anything: the operator comes from a pinned
/// consent record, its terms come from that operator's signed manifest,
/// and the keys come from the identity vault. If no backup operator has
/// been consented to, this resolves to `nil` and Settings shows no
/// backup section — which is correct, not a degraded state.
/// Not `@MainActor`.
///
/// It was, and the annotation was not honoured: `entitlementIssuers` is
/// called synchronously from nonisolated `@Sendable` closures that run
/// inside the purchase-flow actor and the entitlement provider, off the
/// main actor. That is a warning in Swift 5 and a hard error in Swift 6,
/// and in the meantime it meant main-actor-annotated code running
/// elsewhere. Everything here is a pure read of a `Sendable` store, so
/// dropping the isolation is the honest fix rather than adding hops that
/// would only make the annotation true.
enum BackupSeat {
    /// The seat value a backup operator declares.
    static let seat = "storage.backup"

    /// Every backup operator this identity has consented to, in the
    /// order the consents were accepted.
    ///
    /// Reads the *active* pinned record per operator. A person who
    /// switched away from an operator has a history of records for it;
    /// only a current one may receive a snapshot. A person who added a
    /// second operator has two active records, and both may — that is
    /// what keeping a history in two places means.
    static func consentedManifests(
        consentStore: any PinnedConsentStore
    ) -> [BackupOperatorManifest] {
        guard let records = try? consentStore.load() else { return [] }
        var seen: Set<String> = []
        var manifests: [BackupOperatorManifest] = []
        // Newest record first, so the active pin wins for a component
        // that has been re-consented.
        for record in records.reversed() where record.isActive {
            guard
                !seen.contains(record.componentId),
                let manifest = record.consentedManifest(),
                manifest.seat == seat,
                let backup = try? BackupOperatorManifest(manifest: manifest)
            else {
                continue
            }
            seen.insert(record.componentId)
            manifests.append(backup)
        }
        // Sorted by componentId, which is the only key here that does
        // not move.
        //
        // Store position looks like acceptance order and is not one:
        // `accept` appends, so re-reading an operator's terms moves it
        // to the tail and reorders the list. `acceptedAt` on the active
        // record moves for the same reason, and the *earliest* record
        // for a component is evicted once its history passes the cap. A
        // list that reshuffles is not cosmetic here — the root view
        // rebuilds the whole backup stack when this list changes, which
        // would throw away a running backup because somebody re-read
        // some terms.
        return manifests.sorted { $0.componentId < $1.componentId }
    }

    /// What to call an operator on screen.
    ///
    /// The manifest `name` the person consented to, else the component
    /// id minus its prefix — the same rule as the seat adapters and the
    /// Blossom catalog, so one operator is not called two different
    /// things in two places. Read from the *pinned* bytes rather than a
    /// live fetch: an operator does not get to relabel itself into
    /// looking like the one beside it in the list.
    @MainActor
    static func displayName(
        componentId: String,
        consentStore: any PinnedConsentStore
    ) -> String {
        if let record = try? consentStore.activeRecord(componentId: componentId),
           let manifest = record.consentedManifest(),
           let name = SeatManifestFields(rawBytes: manifest.rawBytes).name,
           !name.isEmpty {
            return name
        }
        return ModuleConsentFlow.shortComponentId(componentId)
    }

    /// Issuer keys an operator declares. Pinned from the signed
    /// manifest, never from an entitlement — a credential must not be
    /// able to nominate its own authority.
    static func entitlementIssuers(
        componentId: String,
        consentStore: any PinnedConsentStore
    ) -> [String] {
        guard
            let record = try? consentStore.activeRecord(componentId: componentId),
            let manifest = record.consentedManifest(),
            let backup = try? BackupOperatorManifest(manifest: manifest)
        else {
            return []
        }
        return backup.entitlementIssuers
    }

    /// The first declared issuer, as a key.
    ///
    /// Returns `nil` when nothing has been consented to for that
    /// component, or when the operator declared no issuers — a free
    /// operator, which never issues a payment refusal and therefore
    /// never needs one.
    static func entitlementIssuerKey(
        componentId: String,
        consentStore: any PinnedConsentStore
    ) -> Curve25519.Signing.PublicKey? {
        // `AuthorityKey` is the one `onym:key:` parser in this codebase.
        // A second hand-rolled one is a second place for the hex rules
        // to drift.
        for reference in entitlementIssuers(componentId: componentId, consentStore: consentStore) {
            if let key = try? AuthorityKey.publicKey(fromReference: reference) {
                return key
            }
        }
        return nil
    }

    /// Where a restore puts attachment ciphertext it recovered.
    ///
    /// Read by `RestoredBlobClient`, which the media loaders go through
    /// — that wrapping is what makes a restored attachment visible
    /// rather than merely present on disk.
    static func restoredBlobDirectory() throws -> URL {
        try workingDirectory().appending(path: "blobs")
    }

    /// Where sealed snapshots and local backup state live.
    static func workingDirectory() throws -> URL {
        let base = try PersistentStoreOpener.storeDirectory()
        let url = base.appending(path: "Backup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return url
    }
}

/// Seat-scoped keys for the billing layer, derived from the identity
/// vault.
///
/// `OnymBilling` cannot derive these itself — they belong to whichever
/// seat is being bought — and `OnymBackup` must not depend on identity.
/// The composition root is the only place that knows all three, which is
/// why the conformance lives here.
struct IdentitySeatAccessKeys: SeatAccessKeyProviding {
    let identities: IdentityRepository

    func seatSubject(componentId: String) async throws -> String {
        try await material(componentId: componentId).holderReference
    }

    func seatAgreementKey(
        componentId: String
    ) async throws -> Curve25519.KeyAgreement.PrivateKey {
        try await material(componentId: componentId).accessAgreementKey
    }

    private func material(componentId: String) async throws -> BackupKeyMaterial {
        try await BackupKeys.material(deriving: identities, componentId: componentId)
    }
}
