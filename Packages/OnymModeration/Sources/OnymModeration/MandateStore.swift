import Foundation

/// A signed mandate plus everything needed to honor it offline: the
/// consented manifest snapshot (exact bytes — re-verifiable, still
/// renderable if the authority disappears) and the countersignature
/// state.
public struct MandateRecord: Codable, Sendable, Equatable {
    public let mandate: ModerationMandate
    /// The exact manifest bytes `mandate.manifestHash` was computed
    /// over. Never re-fetched, never re-encoded.
    public let manifestBytes: Data
    /// Display name from the directory listing at consent time.
    public let authorityName: String
    /// False while the interface signature is the stub sentinel — a
    /// record that can never be mistaken for a spec-valid mandate.
    public let countersigned: Bool
    /// Exactly one record is active per identity–device pair.
    /// Switching authorities deactivates the old record without
    /// touching anything else (mandates are immutable, spec §12).
    public var isActive: Bool
    public let createdAt: Date

    public init(
        mandate: ModerationMandate,
        manifestBytes: Data,
        authorityName: String,
        countersigned: Bool,
        isActive: Bool,
        createdAt: Date
    ) {
        self.mandate = mandate
        self.manifestBytes = manifestBytes
        self.authorityName = authorityName
        self.countersigned = countersigned
        self.isActive = isActive
        self.createdAt = createdAt
    }

    /// The consented manifest, decoded from the stored snapshot.
    public func consentedManifest() -> SignedManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(AuthorityManifest.self, from: manifestBytes) else {
            return nil
        }
        return SignedManifest(manifest: manifest, rawBytes: manifestBytes)
    }
}

/// Persistence seam for mandate records. UserDefaults-backed — a
/// mandate is a signed public consent object, not a secret (the
/// signature is worthless without the private key, which stays in
/// the Keychain behind `ModerationSigner`).
public protocol MandateStore: Sendable {
    func load() -> [MandateRecord]
    func save(_ records: [MandateRecord])
}

/// Production `MandateStore`. Keys scoped under
/// `app.onym.ios.moderation.*`; suite injectable for test isolation.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as
/// thread-safe but isn't formally `Sendable`.
public struct UserDefaultsMandateStore: MandateStore, @unchecked Sendable {
    private static let recordsKey = "app.onym.ios.moderation.mandates"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [MandateRecord] {
        guard let data = defaults.data(forKey: Self.recordsKey),
              let records = try? Self.decoder().decode([MandateRecord].self, from: data)
        else { return [] }
        return records
    }

    public func save(_ records: [MandateRecord]) {
        guard let data = try? Self.encoder().encode(records) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }

    /// ISO 8601 dates so persisted mandates stay byte-comparable with
    /// their signing form.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
