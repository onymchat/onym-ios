import Foundation
import OnymTransportBlossom

/// Client selection for a stamped attachment download — the trust
/// boundary between the peer's metadata and the user's network.
///
/// The `server` stamp is an OPTIMIZATION hint for multi-server
/// consistency — "this blob lives on that one of YOUR servers" — never
/// an instruction from the peer. It decodes straight off the wire and
/// bubbles auto-load on render, so honoring an arbitrary stamp would
/// let a hostile sender choose the download host: an unauthenticated
/// GET of a per-message-unique path (a read receipt, plus IP/UA) to a
/// third party the moment the recipient scrolls the thread. The stamp
/// is therefore honored ONLY when its normalized origin
/// (scheme+host+port) matches one of the endpoints the USER has
/// configured/consented to; anything else — unknown hosts, malformed
/// stamps, legacy nil stamps — downloads through the live client
/// pointed at the user's own active server.
enum BlossomServerStampPolicy {
    /// The client a stamped attachment downloads through: `live` bound
    /// to the MATCHED allowlist URL when the stamp is https and its
    /// origin is in `allowedServers`, plain `live` otherwise.
    ///
    /// This is the PEER-influenced trust level: https is required (a
    /// peer must not be able to steer traffic to cleartext or odd
    /// schemes), the origin must be one the user configured, and the
    /// request is built from the allowlist's own URL — the stamp's
    /// origin proves membership, but its path/query are still
    /// peer-chosen bytes and must never shape the request, even
    /// against the user's own server. The user's own hand-typed
    /// endpoints (send/retry binding) live at the trusted level in
    /// `bound(toServer:)` instead, where http local-dev URLs are fine.
    static func client(
        forStamp server: String?,
        allowedServers: [URL],
        live: any BlossomClient
    ) -> any BlossomClient {
        guard let server,
              let stamped = URL(string: server),
              stamped.scheme?.lowercased() == "https",
              let stampedKey = originKey(stamped),
              let matched = allowedServers.first(where: { originKey($0) == stampedKey })
        else { return live }
        return live.bound(toServer: matched.absoluteString)
    }

    /// Normalized scheme+host+port comparison key; default ports
    /// (443/https, 80/http) fold away so `https://a.example` and
    /// `https://a.example:443` are the same origin. `nil` when the URL
    /// has no scheme or host — such a stamp is never comparable and
    /// never honored.
    static func originKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort: Int? = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
