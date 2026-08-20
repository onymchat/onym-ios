import Foundation
import OnymFoundation

/// The credential a billing broker issues after a purchase, and the only
/// thing a seat operator ever sees of that purchase.
///
/// Shape and semantics come from `WHITEPAPER.md` §17.5. It carries no
/// store account, no transaction identifier, and no global Onym
/// identity — the commercial relationship and the access credential are
/// deliberately disjoint, so an operator learns the seat key and the
/// plan and nothing about the buyer.
///
/// House format, not a JWT: canonical JSON with a detached Ed25519
/// signature, verified over the same canonical bytes every other signed
/// document in this system uses. That is not a stylistic preference —
/// the broker, the operator, and this client must agree on *bytes*, and
/// there is already exactly one implementation of those rules here.
public struct SeatEntitlement: Sendable, Equatable {
    public let version: Int
    /// `onym:key:<hex>` of the broker that issued it.
    public let issuer: String
    /// `onym:component:<id>` of the seat it is good at. An entitlement
    /// presented to any other component is not merely useless, it is
    /// refused — one operator never receives another's credential.
    public let audience: String
    /// `onym:seat-key:<64 lowercase hex>` — the holder key this is bound
    /// to, byte for byte the value that seat's requests are signed with.
    public let subject: String
    public let offerId: String
    /// Random, non-reusable. The revocation epoch names these.
    public let entitlementId: String
    public let notBefore: Date
    public let expiresAt: Date
    /// Purchased units for a consumable; `nil` for a subscription.
    /// Integer or string only — the canonical form refuses floats.
    public let quota: Int?
    /// Where the broker publishes its revocation epochs.
    public let status: String?

    /// The exact bytes the broker signed over. Never re-encoded.
    public let rawBytes: Data
    public let signature: Data

    public func isCurrent(at now: Date = Date()) -> Bool {
        now >= notBefore && now < expiresAt
    }
}

extension SeatEntitlement {
    static let documentType = "SeatEntitlement"

    /// Decode without verifying. Callers must go through
    /// `SeatEntitlementVerifier` before treating one as an entitlement —
    /// this exists so the verifier has something to check.
    public static func decode(raw: Data) throws -> SeatEntitlement {
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw BillingError.malformedEntitlement
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty else {
                throw BillingError.malformedEntitlement
            }
            return value
        }
        func date(_ key: String) throws -> Date {
            guard let value = object[key] as? String,
                  let date = BillingFormat.date(fromRFC3339: value)
            else {
                throw BillingError.malformedEntitlement
            }
            return date
        }
        guard
            let version = object["version"] as? Int, version == 1,
            try string("type") == documentType,
            let signatureText = object["signature"] as? String,
            let signature = Data(base64Encoded: signatureText)
        else {
            throw BillingError.malformedEntitlement
        }
        return SeatEntitlement(
            version: version,
            issuer: try string("issuer"),
            audience: try string("audience"),
            subject: try string("subject"),
            offerId: try string("offerId"),
            entitlementId: try string("entitlementId"),
            notBefore: try date("notBefore"),
            expiresAt: try date("expiresAt"),
            // A float here is refused by the canonical encoder anyway;
            // reading it as `Int?` keeps the failure at decode rather
            // than at signature check, where it would look like tamper.
            quota: object["quota"] as? Int,
            status: object["status"] as? String,
            rawBytes: raw,
            signature: signature
        )
    }
}

/// Shared syntax helpers.
enum BillingFormat {
    static let seatKeyPrefix = "onym:seat-key:"
    static let keyPrefix = "onym:key:"

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func date(fromRFC3339 value: String) -> Date? {
        timestampFormatter.date(from: value)
    }

    static func string(fromDate date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    /// Raw key bytes from an `onym:key:` / `onym:seat-key:` reference.
    static func publicKeyBytes(from reference: String, prefix: String) -> Data? {
        guard reference.hasPrefix(prefix) else { return nil }
        let hex = String(reference.dropFirst(prefix.count))
        guard hex.count == 64, isLowercaseHex(hex) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
