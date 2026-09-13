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
        guard (1...12).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw StellarError.badAssetCode(code)
        }
        self = code.count <= 4
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
            let code = try trimmedCode(reader.readFixedOpaque(4))
            return .alphanum4(code: code, issuer: try reader.readAccountID())
        case typeAlphanum12:
            let code = try trimmedCode(reader.readFixedOpaque(12))
            return .alphanum12(code: code, issuer: try reader.readAccountID())
        default:
            // Includes ASSET_TYPE_POOL_SHARE. A liquidity-pool share is
            // a real asset type this app has no screen for; refusing it
            // by name here is better than decoding it into something
            // that renders as an ordinary trustline.
            throw XDRError.unknownDiscriminant(type: "Asset", value: type)
        }
    }

    /// Codes are right-padded with **zero bytes**, not spaces. A
    /// space-padded code is a different asset.
    private static func paddedCode(_ code: String, width: Int) -> Data {
        var bytes = Data(code.utf8)
        bytes.append(Data(repeating: 0, count: max(0, width - bytes.count)))
        return bytes.prefix(width)
    }

    private static func trimmedCode(_ bytes: Data) throws -> String {
        let significant = Data(bytes.prefix(while: { $0 != 0 }))
        guard let code = String(data: significant, encoding: .utf8), !code.isEmpty else {
            throw StellarError.badAssetCode("<non-UTF8>")
        }
        return code
    }
}
