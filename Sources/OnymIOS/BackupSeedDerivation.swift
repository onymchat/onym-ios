import Foundation
import OnymBackup
import OnymIdentity

/// Wires the identity vault to the backup seat's key derivation.
///
/// The conformance lives here, in the composition root, rather than in
/// either package: `OnymIdentity` must not learn about backup, and
/// `OnymBackup` must not gain a dependency on identity. The app is the
/// only place that knows both exist, which is the same seam every other
/// cross-package dependency in this target goes through.
///
/// Nothing but 32 derived bytes crosses. The seed is reconstructed
/// inside the actor, used, and zeroed.
extension IdentityRepository: BackupSeedDeriving {}
