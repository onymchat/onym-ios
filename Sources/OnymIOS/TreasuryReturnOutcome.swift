import Observation

/// What happened to a signed transaction a wallet handed back through
/// `onym://tx`.
///
/// The paste path surfaces its failures inside the sheet; the deeplink
/// path discarded its result entirely, so a wallet returning an
/// envelope for an expired or already-signed proposal — or for nothing
/// this device holds — looked identical to success. Attribution is by
/// verification, so "nothing accepted it" is a perfectly ordinary
/// outcome and the person needs to be told.
@Observable
@MainActor
final class TreasuryReturnOutcome {
    /// Set when a return link has been handled; cleared when the alert
    /// is dismissed.
    var message: String?

    func adopted() {
        message = String(localized: "Your signature was added to the proposal.")
    }

    func notAdopted() {
        message = String(
            localized: "That signed transaction didn't match anything waiting for a signature here. It may have already gone through, or expired."
        )
    }
}
