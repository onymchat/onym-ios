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
    /// to the stamp when the stamp's origin is in `allowedServers`,
    /// plain `live` otherwise.
    static func client(
        forStamp server: String?,
        allowedServers: [URL],
        live: any BlossomClient
    ) -> any BlossomClient {
        guard let server,
              let stamped = URL(string: server),
              let stampedKey = originKey(stamped),
              allowedServers.contains(where: { originKey($0) == stampedKey })
        else { return live }
        return live.bound(toServer: server)
    }

    /// Normalized scheme+host+port comparison key. `nil` when the URL
    /// has no scheme or host — such a stamp is never comparable and
    /// never honored.
    static func originKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
