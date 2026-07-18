import CryptoKit
import Foundation

/// AES-GCM seal/open for chat image blobs, with a **per-image random
/// key**. The uploaded blob is `AES.GCM.SealedBox.combined`
/// (nonce ‖ ciphertext ‖ tag), so the whole blob is self-describing and
/// no separate nonce has to travel in `ChatImageAttachment`. Blossom
/// addresses blobs by the SHA-256 of these stored bytes, which the
/// receiver re-checks before decrypting.
enum ChatImageCrypto {

    struct Sealed: Equatable {
        /// 32-byte AES-GCM key (goes into `ChatImageAttachment.encKey`).
        let key: Data
        /// Encrypted blob to upload (`SealedBox.combined`).
        let blob: Data
        /// Lowercase hex SHA-256 of `blob` (the Blossom address).
        let sha256Hex: String
    }

    enum CryptoError: Error, Equatable {
        case sealFailed
        case hashMismatch
    }

    /// Encrypt `plaintext` under a fresh random key.
    static func seal(_ plaintext: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw CryptoError.sealFailed }
        let keyData = key.withUnsafeBytes { Data($0) }
        return Sealed(key: keyData, blob: combined, sha256Hex: sha256Hex(combined))
    }

    /// Verify `blob`'s hash matches `expectedSha256Hex`, then decrypt
    /// with `key`. Throws `hashMismatch` if the downloaded bytes don't
    /// match the address in the payload (tamper / wrong-blob guard).
    static func open(blob: Data, key: Data, expectedSha256Hex: String) throws -> Data {
        guard sha256Hex(blob).caseInsensitiveCompare(expectedSha256Hex) == .orderedSame else {
            throw CryptoError.hashMismatch
        }
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
