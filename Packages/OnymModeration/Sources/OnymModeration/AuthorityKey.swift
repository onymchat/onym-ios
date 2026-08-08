import Foundation
import CryptoKit

/// The one parser for authority signing keys. Both forms feed through
/// it — the directory listing's base64 `operatorPublicKeyBase64` and the
/// manifest's `onym:key:<hex>` `operator` field — so the fetcher can
/// require the manifest to declare *byte-for-byte* the key the directory
/// pins (`AuthorityManifestFetcher`), and verdict verification can key
/// on that same parsed key (`VerdictValidator`). One parser, one trust
/// root.
public enum AuthorityKey {
    /// Prefix of the spec's key-reference form, `onym:key:<hex>`.
    public static let referencePrefix = "onym:key:"

    /// Raw Ed25519 public key bytes from an `onym:key:<hex>` reference
    /// (32 bytes, hex-encoded — the form mandates carry). Any other
    /// shape throws: a reference this client can't parse is not a key it
    /// can pin consent to.
    public static func rawBytes(fromReference reference: String) throws -> Data {
        guard reference.hasPrefix(referencePrefix) else {
            throw ModerationError.keyInvalid("not an \(referencePrefix) reference")
        }
        let hex = reference.dropFirst(referencePrefix.count)
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            throw ModerationError.keyInvalid("\(referencePrefix) reference is not 32 hex-encoded bytes")
        }
        var bytes = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw ModerationError.keyInvalid("\(referencePrefix) reference is not hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Raw Ed25519 public key bytes from the directory listing's base64
    /// encoding.
    public static func rawBytes(fromBase64 base64: String) throws -> Data {
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else {
            throw ModerationError.keyInvalid("operator key is not 32 base64-encoded bytes")
        }
        return bytes
    }

    public static func publicKey(fromReference reference: String) throws -> Curve25519.Signing.PublicKey {
        try publicKey(rawBytes: rawBytes(fromReference: reference))
    }

    public static func publicKey(fromBase64 base64: String) throws -> Curve25519.Signing.PublicKey {
        try publicKey(rawBytes: rawBytes(fromBase64: base64))
    }

    private static func publicKey(rawBytes: Data) throws -> Curve25519.Signing.PublicKey {
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: rawBytes)
        } catch {
            throw ModerationError.keyInvalid("not an Ed25519 public key")
        }
    }
}
