import Foundation

/// Glue between iOS `URL`s and the platform-agnostic
/// `IntroCapability.fromLink` decoder. Lives in `Transport/` so the
/// `Group/` package stays UI-framework-free (Foundation only —
/// testable on plain XCTest).
///
/// One function:
///
///  - `introCapability(from:)` is pure (`URL?` in,
///    `IntroCapability?` out) and unit-testable. Holds the
///    **scheme/host allowlist** — the Info.plist `CFBundleURLTypes`
///    + Universal Links AASA already gate inbound URLs to
///    `https://onym.chat/join*` and `onym://join`, but a
///    misconfigured share target could still surface other URLs
///    to `.onOpenURL`. We re-check here as defense in depth and
///    so the pre-flight reasoning lives in code, not in
///    Info.plist.
///
/// Returns `nil` for non-deeplink URLs so callers can fall through
/// to normal app launch without special-casing.
///
/// Mirrors onym-android's `DeeplinkCapture.kt`.
enum DeeplinkCapture {

    /// Allowlist of `(scheme, host)` pairs that may carry an
    /// `IntroCapability`. Mirrors the URL-types in `Info.plist`
    /// + the `applinks:onym.chat` entitlement; keep them in
    /// lockstep.
    private static let allowed: Set<Pair> = [
        Pair(scheme: "https", host: "onym.chat"),
        Pair(scheme: "onym", host: "join"),
    ]

    /// Extract a capability from a `URL`. Returns `nil` for:
    ///  - non-onym URLs (host/scheme not on the allowlist)
    ///  - URLs that parse but have no `c=` query parameter
    ///  - URLs with a malformed `c=` payload (bad base64, bad JSON,
    ///    wrong byte sizes)
    ///
    /// Tolerates `nil` URL so callers can pipe `.onOpenURL`'s
    /// optional-style argument straight through.
    static func introCapability(from url: URL?) -> IntroCapability? {
        guard let url else { return nil }
        return introCapability(fromString: url.absoluteString)
    }

    /// String overload — useful for `NSUserActivity.webpageURL`
    /// fallbacks and for the unit tests (which never need a real
    /// `URL` ceremony).
    static func introCapability(fromString rawURL: String?) -> IntroCapability? {
        guard let rawURL, !rawURL.isEmpty else { return nil }
        guard let comps = URLComponents(string: rawURL),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased()
        else { return nil }
        guard allowed.contains(Pair(scheme: scheme, host: host)) else { return nil }
        return IntroCapability.fromLink(rawURL)
    }

    private struct Pair: Hashable {
        let scheme: String
        let host: String
    }
}
