import Foundation

/// Stable opaque handle for one of the user's identities.
///
/// Backed by a UUID, but type-distinct so the compiler stops us from
/// accidentally passing a `UUID` from another domain (e.g. an
/// `OnymInvitee.id`) anywhere an identity is expected.
///
/// Persisted via the keychain `kSecAttrService` suffix
/// (`chat.onym.ios.identity.<uuidString>`) and inside `ChatGroup` rows
/// (post-PR-3) so any group can be traced back to the identity that
/// owns it without a separate join table.
struct IdentityID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// `nil` if `string` isn't a parseable UUID. Used when reconstructing
    /// the ID from a keychain service suffix or a persisted ChatGroup row.
    init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    var description: String { rawValue.uuidString }

    // Codable round-trips as the UUID's string form so persisted JSON +
    // keychain service names stay readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        guard let uuid = UUID(uuidString: str) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "IdentityID: \(str.prefix(40)) is not a UUID"
            )
        }
        self.rawValue = uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}
