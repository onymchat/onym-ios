import Foundation
import Observation
import OnymBackup
import OnymDiscovery
import OnymFoundation

/// Apply step of the backup catalog picker's consent flow, extracted
/// from the `OnymIOSApp` composition root for the same reason
/// `BlossomCatalogConsent` was: the one piece with real behavior should
/// be unit-testable without standing up a screen.
///
/// **It writes nothing, and that is the whole design.** The three
/// transport pickers apply a consent by copying an endpoint into a
/// repository, because their repositories — not the consent store —
/// are the operational source of truth for what the app connects to.
/// The backup seat has no such repository: `BackupSeat.consentedManifests`
/// reads the pinned consent records directly, and
/// `BackupSeatComposer` builds one stack per record it finds there. A
/// second copy of the operator kept anywhere else would be a second
/// place for "who holds my history" to drift from what the person
/// actually agreed to, and the two could disagree after a withdrawal —
/// `stopBackingUp` withdraws the consent and nothing else, which is
/// exactly right only while consent IS the record.
///
/// So the apply step's job is not to add anything. It is to refuse:
/// this is the last moment before the person is told "Service added",
/// and it is where a manifest that cannot back anything up has to say
/// so.
enum BackupCatalogConsent {
    /// Validate that the consented manifest describes an operator this
    /// build can actually use, and throw if it does not.
    ///
    /// The check is `BackupOperatorManifest(manifest:)` itself — the
    /// same initializer `BackupSeat.consentedManifests` runs over every
    /// pinned record — rather than a hand-rolled endpoint scan beside
    /// it. Anything the parse refuses here is something
    /// `consentedManifests` would silently skip later, and the
    /// difference between the two spellings is what a person sees: a
    /// sentence saying this operator's manifest is unusable, versus a
    /// "Service added" screen followed by a Settings section that never
    /// appears.
    ///
    /// `invalidEndpoint` is translated to `ModuleApplyError.noUsableEndpoint`
    /// because it is precisely the condition that error names — a
    /// manifest with no read-write https endpoint is as unusable to the
    /// backup seat as a manifest with no wss endpoint is to a Nostr
    /// relay — and because the consent flow renders that case with the
    /// honest two-part message: the consent was recorded, the service
    /// was not added. The other refusals (an unimplemented profile,
    /// missing terms, a capability set short of what the profile needs)
    /// are rethrown as themselves and land on the flow's generic
    /// "couldn't be added" wording; inventing a fake `noUsableEndpoint`
    /// for them would tell the person to look at an endpoint that is
    /// fine.
    ///
    /// Nothing is undone on the way out. By the time `apply` runs the
    /// consent record is already pinned — `ModuleConsentFlow` writes it
    /// first on purpose — and a refused manifest simply never becomes a
    /// `BackupOperatorManifest`, so it contributes no stack, no upload
    /// and no Settings row. The record stays as history of what was
    /// reviewed, which is what the consent store is for.
    static func apply(manifest: SignedServiceManifest) throws {
        do {
            _ = try BackupOperatorManifest(manifest: manifest)
        } catch BackupError.invalidEndpoint {
            throw ModuleApplyError.noUsableEndpoint
        }
    }
}

/// Raised when a backup operator is consented to, so the root view
/// re-resolves the Device Backup screen without waiting for the
/// Settings tab to be visited again.
///
/// RootView already re-resolves on two events: the Settings tab being
/// selected, and the moderation consent cover closing. Neither fires
/// here. Consent to a backup operator is given from a sheet pushed on
/// top of the Settings tab, so the tab never changes — and the person
/// who just agreed to back up their history walks back to a Settings
/// screen with no Device Backup row on it, which reads exactly like
/// the consent not having worked.
///
/// A signal rather than a direct call because the two ends belong to
/// different layers: the picker's apply closure is built in the
/// composition root and knows nothing about view state, and the
/// resolution is `RootView`'s, guarded by its own in-flight bookkeeping
/// so a rebuild never lands twice. Same shape, and the same reason, as
/// `OnboardingRestartController`.
///
/// The revision is a counter, not a flag, so two consents in a row are
/// two changes: an `onChange` on a `Bool` that was already true would
/// swallow the second. Nothing consumes the value itself.
@MainActor
@Observable
final class BackupConsentSignal {
    private(set) var revision = 0

    /// A consent record was just written for a backup operator.
    func consentRecorded() {
        revision &+= 1
    }
}
