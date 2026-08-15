import Foundation

/// User-facing rendering of discovery failures — one place so the
/// repository's per-source status and the Settings add-provider flow
/// describe the same error the same way.
public enum DiscoveryUserMessage {
    /// Short, readable one-liner for any error the discovery stack
    /// throws (trust rejections, fetch limits, plain reachability).
    public static func message(for error: Error) -> String {
        switch error {
        case let DiscoveryTrustError.providerManifestInvalid(reason):
            return String(localized: "Provider manifest rejected: \(reason)")
        case let DiscoveryTrustError.snapshotInvalid(reason):
            return String(localized: "Catalog snapshot rejected: \(reason)")
        case DiscoveryTrustError.snapshotExpired:
            return String(localized: "Catalog snapshot has expired.")
        case DiscoveryTrustError.policyUnavailable:
            return String(localized: "The provider's policy document couldn't be verified against its pinned digest.")
        case DiscoveryTrustError.entryManifestMismatch:
            return String(localized: "A listed service's manifest doesn't match the bytes its catalog entry pinned.")
        case let DiscoveryTrustError.entryManifestInvalid(reason):
            return String(localized: "A listed service's manifest failed verification: \(reason)")
        case DiscoveryTrustError.sourceConflict:
            return String(localized: "Two of your providers list the same service with different manifests.")
        case DiscoveryFetchError.rateLimited:
            return String(localized: "The provider is rate limiting requests.")
        case DiscoveryFetchError.oversize:
            return String(localized: "The provider served an oversized document.")
        case let DiscoveryFetchError.badStatus(code):
            return String(localized: "Couldn't reach the provider (status \(code)).")
        case is URLError:
            return String(localized: "Couldn't reach the provider.")
        default:
            return String(localized: "Couldn't refresh the provider.")
        }
    }

    /// Whether a failure is an **integrity** finding (a document that
    /// arrived but failed verification — bad signature, rollback,
    /// equivocation, digest mismatch) as opposed to plain
    /// unreachability or staleness. The settings UI badges these
    /// differently: a dead host is an outage, a failing signature is a
    /// warning about the provider itself. `snapshotExpired` is
    /// deliberately NOT integrity: a snapshot past its window means
    /// the provider stopped republishing — an operational lapse, same
    /// family as an outage — not evidence of tampering.
    public static func isIntegrityFailure(_ error: Error) -> Bool {
        switch error {
        case DiscoveryTrustError.providerManifestInvalid,
             DiscoveryTrustError.snapshotInvalid,
             DiscoveryTrustError.policyUnavailable,
             DiscoveryTrustError.entryManifestMismatch,
             DiscoveryTrustError.entryManifestInvalid,
             DiscoveryTrustError.sourceConflict:
            return true
        default:
            return false
        }
    }
}
