import Foundation

/// The deeplink-shareable capability for the Level-2 sender-approval
/// invite flow. Intentionally minimal — carries **no `groupSecret`**,
/// **no member roster**. A bearer of this capability can only do one
/// thing: send a "request to join" to the inviter's intro inbox. The
/// actual `GroupInvitationPayload` (with `groupSecret` + members) is
/// sealed by the inviter only after they tap Approve.
///
/// ## Wire shape
///
/// Encoded as `Base64(JSON)` and ferried via either:
///
///  - `https://onym.app/join?c=<base64>` — the Universal Link form;
///    the OS routes it straight to the app on devices that have
///    fetched the AASA file.
///  - `onym://join?c=<base64>` — custom-scheme fallback for clients
///    where Universal Link routing hasn't kicked in yet.
///
/// The query parameter is `c` (capability) — kept short to keep the
/// URL pasteable through SMS-character-counted channels.
///
/// ## Per-invite ephemeral key
///
/// `introPublicKey` is a **fresh X25519 pubkey minted per invite** —
/// never the inviter's identity inbox key. The matching private key
/// stays on the inviter's device (PR-2 keystore). This gives the
/// inviter per-link revocation: stop listening on a given intro tag
/// → the link goes silent. It also means link interception doesn't
/// leak the inviter's long-term inbox key.
///
/// ## What's safe to ship in `groupName` and `rules`
///
/// Optional, plaintext, **public** — both of them. The link transits
/// cleartext channels (Telegram, SMS, etc.), so anyone observing the
/// link can read them. `groupName` is the joiner's "join this group?"
/// preview; `rules` is what they are asked to agree to before their
/// name and keys leave the device, and it has to travel *with* the
/// link because there is no other channel to fetch it from before
/// joining — a joiner asked to agree to a hash they cannot read has
/// not agreed to anything. For sensitive group names or rules, leave
/// them nil and let the inviter convey context out-of-band.
///
/// `rules` is capped at `GroupRules.maxBytes` — UTF-8 bytes, which is
/// the only unit Swift and Kotlin compute identically, and the unit the
/// link actually spends — so the encoded link still fits a scannable QR
/// code. See that constant for the measurements.
///
/// ## Cross-platform contract
///
/// The wire shape mirrors onym-android's `IntroCapability.kt` byte
/// for byte:
///
///  - JSON keys: `intro_pub`, `group_id`, `group_name`, `rules`
///  - Inner field encoding: standard base64 *with* padding
///    (Swift's default `JSONEncoder.dataEncodingStrategy = .base64`,
///     matching Android's `Base64.getEncoder()`)
///  - Outer URL payload: URL-safe base64 *without* padding
///    (`+`/`/` → `-`/`_`, no `=` padding)
///  - `group_name` omitted from JSON when nil (custom `encode(to:)`
///    using `encodeIfPresent` — matches Android's
///    `encodeDefaults = false`)
public struct IntroCapability: Codable, Equatable, Sendable, Identifiable {
    /// `id` for SwiftUI `.sheet(item:)` / `.fullScreenCover(item:)`
    /// presentation. The intro pubkey is uniformly random per
    /// invite, so it's a stable identity for one in-flight
    /// capability — two distinct invites can never collide.
    public var id: Data { introPublicKey }

    /// X25519 32-byte pubkey, freshly minted per invite. Encrypts
    /// the joiner's request envelope; the inviter's app holds the
    /// matching private key.
    public let introPublicKey: Data

    /// 32-byte canonical bls12-381 Fr (BE). The on-chain `group_id`
    /// the joiner is asking to join. Lets the joiner verify the
    /// group exists on chain (`get_commitment`) before sending a
    /// request — protects against a forged link pointing at a
    /// non-existent group.
    public let groupId: Data

    /// Optional display name. Public — see type doc.
    public let groupName: String?

    /// The group's rules, as the founder wrote them. Public — see type
    /// doc. Canonical (ends-trimmed) and non-empty, or nil.
    ///
    /// Carried so the joiner can read them on the confirmation screen
    /// and sign them: the signature in `JoinRequestPayload` covers
    /// `SHA256` of exactly this text, which is why it is stored the way
    /// `GroupRules.canonical` produces rather than however it was
    /// typed. A link minted by an older build has none, and a joiner
    /// reaching it is asked to agree to nothing.
    public let rules: String?

    static let appLinkBase = "https://onym.app/join?c="
    static let customSchemeBase = "onym://join?c="

    enum CodingKeys: String, CodingKey {
        case introPublicKey = "intro_pub"
        case groupId = "group_id"
        case groupName = "group_name"
        case rules = "rules"
    }

    public init(
        introPublicKey: Data,
        groupId: Data,
        groupName: String? = nil,
        rules: String? = nil
    ) throws {
        guard introPublicKey.count == 32 else {
            throw InvalidIntroCapability.shape(
                "introPublicKey: expected 32 bytes, got \(introPublicKey.count)"
            )
        }
        guard groupId.count == 32 else {
            throw InvalidIntroCapability.shape(
                "groupId: expected 32 bytes, got \(groupId.count)"
            )
        }
        let normalizedRules = GroupRules.normalized(rules)
        if let normalizedRules, !GroupRules.fits(normalizedRules) {
            throw InvalidIntroCapability.shape(
                "rules: expected at most \(GroupRules.maxBytes) UTF-8 bytes, "
                + "got \(normalizedRules.utf8.count)"
            )
        }
        self.introPublicKey = introPublicKey
        self.groupId = groupId
        self.groupName = groupName
        self.rules = normalizedRules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pub = try c.decode(Data.self, forKey: .introPublicKey)
        let gid = try c.decode(Data.self, forKey: .groupId)
        guard pub.count == 32 else {
            throw InvalidIntroCapability.shape(
                "introPublicKey: expected 32 bytes, got \(pub.count)"
            )
        }
        guard gid.count == 32 else {
            throw InvalidIntroCapability.shape(
                "groupId: expected 32 bytes, got \(gid.count)"
            )
        }
        let rules = GroupRules.normalized(
            try c.decodeIfPresent(String.self, forKey: .rules)
        )
        // Rejected, not truncated. Both platforms enforce the cap when
        // they mint a link, so an over-long one is corruption or
        // mischief — and the failure modes of the alternatives are
        // worse than an unusable link: truncating would have the joiner
        // sign rules that end mid-sentence, and dropping the field
        // would walk them into a group whose rules they were never
        // shown while the founder believes otherwise.
        if let rules, !GroupRules.fits(rules) {
            throw InvalidIntroCapability.shape(
                "rules: expected at most \(GroupRules.maxBytes) UTF-8 bytes, "
                + "got \(rules.utf8.count)"
            )
        }
        self.introPublicKey = pub
        self.groupId = gid
        self.groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        self.rules = rules
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(introPublicKey, forKey: .introPublicKey)
        try c.encode(groupId, forKey: .groupId)
        try c.encodeIfPresent(groupName, forKey: .groupName)
        try c.encodeIfPresent(rules, forKey: .rules)
    }

    /// Encode to the base64-of-JSON payload that lands in the URL
    /// query string. URL-safe base64 (no `=` padding, no `+`/`/`)
    /// so the result drops straight into a query without
    /// percent-encoding.
    public func encode() -> String {
        let json: Data
        do {
            json = try Self.jsonEncoder.encode(self)
        } catch {
            preconditionFailure("IntroCapability JSON encode failed: \(error)")
        }
        return Self.urlSafeNoPaddingBase64(json)
    }

    /// Build the Universal Link form. Drop into a share sheet or
    /// a chat message body.
    public func toAppLink() -> String { "\(Self.appLinkBase)\(encode())" }

    /// Build the custom-scheme fallback. Same payload, different
    /// scheme — for testing in environments where Universal Link
    /// routing hasn't been validated yet.
    public func toCustomSchemeLink() -> String { "\(Self.customSchemeBase)\(encode())" }

    /// Inverse of `encode()`. Throws `InvalidIntroCapability` on any
    /// malformed input (bad base64, bad JSON, wrong key sizes).
    public static func decode(_ payload: String) throws -> IntroCapability {
        guard let raw = urlSafeNoPaddingBase64Decode(payload) else {
            throw InvalidIntroCapability.base64("base64 decode failed")
        }
        do {
            return try jsonDecoder.decode(IntroCapability.self, from: raw)
        } catch let err as InvalidIntroCapability {
            throw err
        } catch let DecodingError.dataCorrupted(ctx) {
            throw InvalidIntroCapability.json("JSON decode failed: \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, _) {
            throw InvalidIntroCapability.json("missing required key: \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw InvalidIntroCapability.json("type mismatch: \(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw InvalidIntroCapability.json("missing value: \(ctx.debugDescription)")
        } catch {
            throw InvalidIntroCapability.json("decode failed: \(error)")
        }
    }

    /// Pull the `c=…` query parameter out of any link form
    /// (`appLinkBase` or `customSchemeBase`) + decode it. Returns
    /// nil if the URL doesn't carry a capability — caller decides
    /// whether that's an error.
    public static func fromLink(_ link: String) -> IntroCapability? {
        guard let url = URL(string: link),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        guard let items = comps.queryItems else { return nil }
        for item in items where item.name == "c" {
            if let value = item.value {
                return try? decode(value)
            }
        }
        return nil
    }

    /// Build a share-text payload bundling the link with a human
    /// nudge. Inviter pastes this into their share-sheet target.
    public static func shareText(link: String, groupName: String?) -> String {
        if let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return "Join \"\(name)\" on Onym: \(link)"
        }
        return "Join my chat on Onym: \(link)"
    }

    // MARK: - URL-safe base64 helpers

    private static func urlSafeNoPaddingBase64(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    private static func urlSafeNoPaddingBase64Decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
        t = t.replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        t.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: t)
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        // Default `.base64` + matches Android `Base64.getEncoder()`.
        e.dataEncodingStrategy = .base64
        // Without this one capability can encode to two different
        // link strings. Decoding is order-agnostic, so links keep working.
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()
}

/// Decode-side failures from `IntroCapability.decode` /
/// `IntroCapability.fromLink`. Caller maps to user-facing copy.
public enum InvalidIntroCapability: Error, Equatable, CustomStringConvertible {
    case base64(String)
    case json(String)
    case shape(String)

    public var description: String {
        switch self {
        case .base64(let m): return "InvalidIntroCapability(base64): \(m)"
        case .json(let m): return "InvalidIntroCapability(json): \(m)"
        case .shape(let m): return "InvalidIntroCapability(shape): \(m)"
        }
    }
}
