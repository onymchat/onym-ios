import Foundation

/// An asset: either the native lumen, or a code issued by an account.
///
/// The alphanum4/alphanum12 split is not a detail the caller should
/// have to make — it is decided entirely by the code's length, so
/// `init(code:issuer:)` decides it and the XDR layer reads it back off
/// the discriminant. Getting it wrong produces a different asset with
/// the same name, which is a trustline to nothing.
public enum StellarAsset: Equatable, Hashable, Sendable, Codable {
    case native
    /// 1–4 characters. `assetCode` is padded to exactly 4 bytes on the
    /// wire.
    case alphanum4(code: String, issuer: StellarAccountID)
    /// 5–12 characters, padded to exactly 12 bytes on the wire.
    case alphanum12(code: String, issuer: StellarAccountID)

    /// Build from a code and issuer, picking the right width. An empty
    /// or over-long code throws rather than being truncated: a
    /// truncated code is a valid-looking asset that nobody issued.
    ///
    /// Codes are restricted to ASCII alphanumerics, which is what the
    /// protocol permits. This also rules out the homoglyph substitution
    /// that makes a fake "USDC" indistinguishable on screen — though it
    /// does not make the *issuer* safe, which is why the issuer is
    /// always shown alongside the code in the UI.
    public init(code: String, issuer: StellarAccountID) throws {
        guard Self.isPermitted(
            code,
            minBytes: Self.alphanum4Bytes.min,
            maxBytes: Self.alphanum12Bytes.max
        ) else {
            throw StellarError.badAssetCode(code)
        }
        self = Data(code.utf8).count <= 4
            ? .alphanum4(code: code, issuer: issuer)
            : .alphanum12(code: code, issuer: issuer)
    }

    public var code: String {
        switch self {
        case .native: "XLM"
        case .alphanum4(let code, _), .alphanum12(let code, _): code
        }
    }

    public var issuer: StellarAccountID? {
        switch self {
        case .native: nil
        case .alphanum4(_, let issuer), .alphanum12(_, let issuer): issuer
        }
    }

    // MARK: - Codable

    /// Hand-written so that JSON reaching this type is validated the
    /// same way the wire and the constructor are.
    ///
    /// The synthesized conformance bypassed `init(code:issuer:)` — the
    /// cases are public — so `{"alphanum12":{"code":"USD",…}}` built an
    /// asset that violates the width class, and `paddedCode`'s
    /// precondition then *trapped* when it was encoded. A crash on
    /// hostile input is not a validation strategy. `StellarAccountID`
    /// already validates in `init(from:)`; this now matches.
    private enum CodingKeys: String, CodingKey {
        case code
        case issuer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        guard let issuer = try container.decodeIfPresent(
            StellarAccountID.self,
            forKey: .issuer
        ) else {
            guard code == "XLM" else {
                throw StellarError.badAssetCode(code)
            }
            self = .native
            return
        }
        self = try StellarAsset(code: code, issuer: issuer)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(issuer, forKey: .issuer)
    }

    // MARK: - XDR

    // AssetType discriminants.
    private static let typeNative: Int32 = 0
    private static let typeAlphanum4: Int32 = 1
    private static let typeAlphanum12: Int32 = 2

    public func encode(to writer: inout XDRWriter) {
        switch self {
        case .native:
            writer.writeInt32(Self.typeNative)
        case .alphanum4(let code, let issuer):
            writer.writeInt32(Self.typeAlphanum4)
            writer.writeFixedOpaque(Self.paddedCode(code, width: 4))
            writer.writeAccountID(issuer)
        case .alphanum12(let code, let issuer):
            writer.writeInt32(Self.typeAlphanum12)
            writer.writeFixedOpaque(Self.paddedCode(code, width: 12))
            writer.writeAccountID(issuer)
        }
    }

    public static func decode(from reader: inout XDRReader) throws -> StellarAsset {
        let type = try reader.readInt32()
        switch type {
        case typeNative:
            return .native
        case typeAlphanum4:
            let code = try trimmedCode(
                reader.readFixedOpaque(4),
                bounds: alphanum4Bytes
            )
            return .alphanum4(code: code, issuer: try reader.readAccountID())
        case typeAlphanum12:
            let code = try trimmedCode(
                reader.readFixedOpaque(12),
                bounds: alphanum12Bytes
            )
            return .alphanum12(code: code, issuer: try reader.readAccountID())
        default:
            // Includes ASSET_TYPE_POOL_SHARE. A liquidity-pool share is
            // a real asset type this app has no screen for; refusing it
            // by name here is better than decoding it into something
            // that renders as an ordinary trustline.
            throw XDRError.unknownDiscriminant(type: "Asset", value: type)
        }
    }

    /// Whether `code` is a code the protocol permits: ASCII
    /// alphanumerics only, within the width.
    ///
    /// Shared by `init(code:issuer:)` and by the decoder, deliberately.
    /// Validating only on construction left the read path open: a
    /// twelve-byte field holds "USD" plus a Cyrillic "С" (U+0421, two
    /// UTF-8 bytes) and decodes to something that renders identically
    /// to USDC on a co-signer's screen. The rule has to hold wherever
    /// an asset comes from, and a proposal's asset comes from the wire.
    static func isPermitted(_ code: String, minBytes: Int, maxBytes: Int) -> Bool {
        let bytes = Data(code.utf8)
        return bytes.count >= minBytes
            && bytes.count <= maxBytes
            && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The byte range each width class permits.
    ///
    /// The **lower** bound on alphanum12 is the load-bearing half.
    /// Without it a twelve-byte field holding "USD" plus nine zeros
    /// decodes to `.alphanum12(code: "USD")`, which `.code` then renders
    /// as "USD" — indistinguishable on a co-signer's screen from the
    /// alphanum4 `USD`, a *different* asset with a different trustline.
    /// stellar-core rejects it, so it is also an asset the network
    /// would never have produced. Neither the constructor tests nor the
    /// fixture round-trip could catch it: `init(code:issuer:)` picks
    /// alphanum4 at four bytes or fewer and so can never build one, and
    /// re-encoding the malformed field is byte-identical.
    ///
    /// Same class as the homoglyph and embedded-zero gaps — two things
    /// with one rendering.
    static let alphanum4Bytes = (min: 1, max: 4)
    static let alphanum12Bytes = (min: 5, max: 12)

    /// Codes are right-padded with **zero bytes**, not spaces. A
    /// space-padded code is a different asset.
    ///
    /// The precondition is the guard on the construction path. The
    /// enum's cases are public, so `.alphanum4(code: "LONGASSET123", …)`
    /// can be written directly, bypassing `init(code:issuer:)`; without
    /// this it would silently encode the first four bytes — a valid
    /// transaction paying a different asset than the one named in the
    /// source. That is a programmer error rather than hostile input, so
    /// it fails loudly here rather than being smuggled onto the wire.
    private static func paddedCode(_ code: String, width: Int) -> Data {
        let bounds = width == alphanum4Bytes.max ? alphanum4Bytes : alphanum12Bytes
        precondition(
            isPermitted(code, minBytes: bounds.min, maxBytes: bounds.max),
            "asset code '\(code)' is not \(bounds.min)–\(bounds.max) ASCII-alphanumeric bytes"
        )
        var bytes = Data(code.utf8)
        bytes.append(Data(repeating: 0, count: max(0, width - bytes.count)))
        return bytes
    }

    private static func trimmedCode(
        _ bytes: Data,
        bounds: (min: Int, max: Int)
    ) throws -> String {
        guard let firstZero = bytes.firstIndex(of: 0) else {
            return try validated(bytes, bounds: bounds)
        }
        // Everything after the first zero must also be zero. Otherwise
        // "US\0DC" and "US\0\0" trim to the same asset from different
        // bytes — the same "two encodings, one value" the XDR reader
        // refuses for padding, and it matters more here because the
        // difference is which asset is being moved.
        let padding = bytes[firstZero...]
        guard padding.allSatisfy({ $0 == 0 }) else {
            throw StellarError.badAssetCode("<embedded zero>")
        }
        return try validated(Data(bytes[..<firstZero]), bounds: bounds)
    }

    private static func validated(
        _ bytes: Data,
        bounds: (min: Int, max: Int)
    ) throws -> String {
        guard let code = String(data: bytes, encoding: .utf8),
              isPermitted(code, minBytes: bounds.min, maxBytes: bounds.max)
        else {
            throw StellarError.badAssetCode(
                String(data: bytes, encoding: .utf8) ?? "<non-UTF8>"
            )
        }
        return code
    }
}
