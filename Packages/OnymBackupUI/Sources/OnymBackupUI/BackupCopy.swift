import Foundation
import OnymBackup

/// Turns anything thrown below this layer into a sentence.
///
/// Every screen in this module renders one of these directly — the
/// backup status row, the consent surface when terms cannot be
/// fetched, the restore screen — and `String(describing:)` on a
/// `BackupError` produces `rejected(code: "quota_exceeded", message:
/// Optional("…"))`. That is a debugger's output shown to somebody
/// trying to find out whether their history is safe.
///
/// The types themselves know how to say it (`BackupError` and
/// `BillingError` both conform to `LocalizedError`); this is the one
/// place that asks, so a surface cannot forget to.
enum BackupCopy {
    static func describe(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "This phone is not online."
        }
        // Deliberately not the error's type name. Someone reading this
        // has learned nothing either way, and a type name invites them
        // to think it means something.
        return "Something went wrong."
    }
}
