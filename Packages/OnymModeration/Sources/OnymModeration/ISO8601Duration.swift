import Foundation

/// The day-granular subset of ISO 8601 durations the moderation spec
/// actually uses (`P1D`, `P3D`, `P30D`, `P365D`, …). Authority
/// manifests declare every window in whole days; supporting the full
/// ISO 8601 grammar (weeks, time components, fractions) would be
/// untestable surface for values no conforming manifest emits.
public struct ISO8601Duration: Sendable, Equatable, Hashable {
    /// The exact string as consented to, e.g. `"P3D"`. Preserved
    /// verbatim so terms render exactly as the manifest declared them.
    public let raw: String
    /// Whole days encoded by `raw`.
    public let days: Int

    public var timeInterval: TimeInterval { TimeInterval(days) * 86_400 }

    public init(days: Int) {
        self.raw = "P\(days)D"
        self.days = days
    }

    /// Parse the `P<n>D` subset. Throws `ModerationError.invalidDuration`
    /// on anything else — a manifest declaring windows this client can't
    /// interpret must fail consent validation, not round to zero.
    public init(parsing raw: String) throws {
        guard raw.hasPrefix("P"), raw.hasSuffix("D"),
              raw.count > 2,
              let days = Int(raw.dropFirst().dropLast()),
              days > 0
        else {
            throw ModerationError.invalidDuration(raw)
        }
        self.raw = raw
        self.days = days
    }
}

extension ISO8601Duration: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        try self.init(parsing: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// A violation class's ban term: a declared duration, or `permanent`
/// (valid per spec §5.2 only on classes whose manifest names an
/// external appellate — checked at consent, not here).
public enum BanTerm: Sendable, Equatable, Hashable {
    case permanent
    case duration(ISO8601Duration)
}

extension BanTerm: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "permanent" {
            self = .permanent
        } else {
            self = .duration(try ISO8601Duration(parsing: raw))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .permanent: try container.encode("permanent")
        case .duration(let duration): try container.encode(duration.raw)
        }
    }
}

/// Whether a ban executes immediately (`non-suspensive`, appeal can
/// only reverse it) or only after the appeal window passes unused
/// (`suspensive`). Spec §5.2 normative constraint 1.
public enum AppealEffect: String, Codable, Sendable, Equatable {
    case suspensive
    case nonSuspensive = "non-suspensive"
}
