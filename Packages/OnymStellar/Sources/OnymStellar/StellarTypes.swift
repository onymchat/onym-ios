import CryptoKit
import Foundation
import OnymFoundation

/// Which Stellar network a transaction is for.
///
/// The passphrase is not a label — it is hashed into every transaction
/// signature (`StellarNetwork.id`), which is what stops a transaction
/// signed on testnet from being replayable on the public network. It
/// therefore travels with every proposal and is checked on receipt.
public enum StellarNetwork: String, Codable, Equatable, Sendable, CaseIterable {
    case testnet
    case publicNet

    public var passphrase: String {
        switch self {
        case .testnet: "Test SDF Network ; September 2015"
        case .publicNet: "Public Global Stellar Network ; September 2015"
        }
    }

    /// SHA-256 of the passphrase — the `networkId` that prefixes the
    /// signature payload.
    public var id: Data {
        Data(SHA256.hash(data: Data(passphrase.utf8)))
    }

    public init?(passphrase: String) {
        guard let match = Self.allCases.first(where: { $0.passphrase == passphrase }) else {
            return nil
        }
        self = match
    }
}

/// A Stellar account, held as the 32 raw bytes that go on the wire with
/// its `G…` spelling alongside.
///
/// Both, rather than one derived on demand, because the two are used in
/// different places and converting at each use site is where a mismatch
/// would hide: the bytes are what gets signed, the string is what a
/// person reads and compares. Constructed only through a checked
/// decode, so an instance of this type is always a valid account ID.
public struct StellarAccountID: Equatable, Hashable, Sendable, Codable {
    public let publicKey: Data
    public let accountID: String

    public init(publicKey: Data) throws {
        guard publicKey.count == 32 else {
            throw StellarError.badPublicKeyLength(publicKey.count)
        }
        self.publicKey = publicKey
        self.accountID = StellarStrKey.encodeAccountID(publicKey)
    }

    public init(accountID: String) throws {
        self.publicKey = try StellarStrKey.decodeAccountID(accountID)
        self.accountID = accountID
    }

    /// Last four bytes of the public key — the `SignatureHint` a
    /// decorated signature carries so a verifier can tell which of an
    /// account's signers produced it without trying all of them.
    ///
    /// A hint is a lookup aid and nothing more: four bytes collide, and
    /// two signers on one account could share one. Verification is
    /// always the Ed25519 check, never the hint.
    public var signatureHint: Data { publicKey.suffix(4) }

    /// The spelling used in UI: first and last six characters. Long
    /// enough to compare by eye, short enough to sit in a row.
    public var abbreviated: String {
        "\(accountID.prefix(6))…\(accountID.suffix(6))"
    }

    // Encoded as the `G…` string rather than as bytes: these values are
    // persisted and cross the wire, and the string form is the one a
    // human can check against a block explorer when something is wrong.
    public init(from decoder: Decoder) throws {
        try self.init(accountID: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(accountID)
    }
}

/// An amount, held in stroops — the integer unit Stellar actually uses.
/// One lumen is 10,000,000 stroops.
///
/// Integer throughout, never `Double`. A binary float cannot represent
/// 0.1 exactly, so round-tripping a user's "0.1 XLM" through `Double`
/// yields an amount that is off by a fraction of a stroop and rounds
/// unpredictably — which is a wrong payment, not a display artefact.
public struct StellarAmount: Equatable, Hashable, Sendable, Comparable {
    public static let stroopsPerUnit: Int64 = 10_000_000

    public let stroops: Int64

    public init(stroops: Int64) {
        self.stroops = stroops
    }

    /// Parse a decimal string. Rejects anything that is not a plain
    /// non-negative decimal with at most seven fractional digits —
    /// no grouping separators, no exponent, no sign, no locale. An
    /// eighth digit is refused rather than rounded: silently dropping
    /// a digit from an amount is exactly the kind of helpfulness that
    /// moves money.
    public init(decimalString: String) throws {
        let parts = decimalString.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2 else {
            throw StellarError.badAmount(decimalString)
        }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard !whole.isEmpty, whole.allSatisfy(\.isASCIIDigit) else {
            throw StellarError.badAmount(decimalString)
        }
        // A decimal point with no digits after it ("1.") is refused
        // rather than read as "1". Trimming a half-typed number is the
        // composing field's job; doing it here would make this type
        // accept input it documents as invalid.
        guard fraction.count <= 7,
              parts.count == 1 || !fraction.isEmpty,
              fraction.allSatisfy(\.isASCIIDigit)
        else {
            throw StellarError.badAmount(decimalString)
        }
        // `padding(toLength:)` on an empty string yields "0000000", so
        // an amount with no decimal point needs no special case.
        let padded = fraction.padding(toLength: 7, withPad: "0", startingAt: 0)
        guard let wholeValue = Int64(whole), let fractionValue = Int64(padded) else {
            throw StellarError.badAmount(decimalString)
        }
        let (scaled, scaleOverflowed) = wholeValue.multipliedReportingOverflow(
            by: Self.stroopsPerUnit
        )
        guard !scaleOverflowed else { throw StellarError.badAmount(decimalString) }
        let (total, addOverflowed) = scaled.addingReportingOverflow(fractionValue)
        guard !addOverflowed else { throw StellarError.badAmount(decimalString) }
        self.stroops = total
    }

    /// Seven fractional digits with trailing zeros trimmed, and at least
    /// one digit after the point kept off — "10", not "10.0000000".
    /// This is the form Horizon and every explorer print, so a user
    /// comparing the two sees the same string.
    ///
    /// The sign is taken from the whole value, not from the integer
    /// division. `-5_000_000 / 10_000_000` is `0` in Swift, so a naive
    /// `"\(whole).\(digits)"` renders −0.5 as "0.5" — a negative amount
    /// shown to a co-signer as a positive one. Amounts are rejected as
    /// negative at the decode boundary now, but this is the rendering
    /// the card uses and it should not depend on that holding.
    public var decimalString: String {
        let magnitude = stroops.magnitude
        let sign = stroops < 0 ? "-" : ""
        let whole = magnitude / UInt64(Self.stroopsPerUnit)
        let fraction = magnitude % UInt64(Self.stroopsPerUnit)
        guard fraction != 0 else { return "\(sign)\(whole)" }
        var digits = String(format: "%07llu", fraction)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(sign)\(whole).\(digits)"
    }

    /// Read an amount off the wire, refusing a negative one.
    ///
    /// Stellar has no negative amounts: a payment, a starting balance
    /// and a trustline limit are all non-negative by definition. But
    /// XDR carries a plain `int64`, so a hostile proposal can put one
    /// there — and every arithmetic and comparison downstream (weight
    /// checks, "is this more than the balance") would then be reasoning
    /// about a number the protocol says cannot exist.
    ///
    /// Rejected at the boundary rather than clamped, because a
    /// transaction that encodes an impossible amount is not a
    /// transaction with a small error in it.
    static func decoded(_ stroops: Int64) throws -> StellarAmount {
        guard stroops >= 0 else { throw StellarError.negativeAmount(stroops) }
        return StellarAmount(stroops: stroops)
    }

    public static func < (lhs: StellarAmount, rhs: StellarAmount) -> Bool {
        lhs.stroops < rhs.stroops
    }

    /// The limit `changeTrust` uses to mean "no ceiling". Also the
    /// largest amount Stellar represents.
    public static let max = StellarAmount(stroops: Int64.max)
}

private extension Character {
    /// Not `isNumber`, which is true for Arabic-Indic digits, fullwidth
    /// digits, and Roman numerals — none of which `Int64(_:)` parses,
    /// and one of which would otherwise pass validation and then fail
    /// conversion.
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

public enum StellarError: Error, Equatable, Sendable {
    case badPublicKeyLength(Int)
    case badAmount(String)
    /// An amount the protocol says cannot exist. See
    /// `StellarAmount.decoded(_:)`.
    case negativeAmount(Int64)
    case badAssetCode(String)
    /// More operations than a Stellar transaction permits.
    case tooManyOperations(Int)
    /// The envelope already carries the protocol's maximum signatures.
    case tooManySignatures(Int)
    /// A signature that did not verify against the transaction hash this
    /// device computed. Never a reason to retry — it means the bytes
    /// signed were not the bytes proposed.
    case signatureDoesNotVerify
    case unsupportedEnvelopeType(Int32)
    /// A string that was meant to be a base64 envelope and is not.
    case notBase64
}
