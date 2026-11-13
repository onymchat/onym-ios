import Foundation

/// The sealed envelope in binary, for the air (spec §4c). The JSON form
/// carries every key and signature as base64 inside JSON; over Bluetooth
/// each byte costs airtime, so the fixed-size fields travel raw:
///
/// ```
/// offset  size  field
///      0     1  format                     0x01 = x25519-aes-256-gcm-v1, version 1
///      1    32  ephemeral_public_key
///     33    64  ephemeral_key_signature
///     97    32  sender_ed25519_public_key
///    129    12  nonce
///    141    16  authentication_tag
///    157     …  ciphertext
/// ```
///
/// A receiver turns it back into exactly the JSON the inbox already opens,
/// so decryption and sender authentication are unchanged.
public enum MeshEnvelope {
    static let format: UInt8 = 0x01
    static let scheme = "x25519-aes-256-gcm-v1"
    static let fields: [(key: String, size: Int)] = [
        ("ephemeral_public_key", 32),
        ("ephemeral_key_signature", 64),
        ("sender_ed25519_public_key", 32),
        ("nonce", 12),
        ("authentication_tag", 16),
    ]
    static let headerSize = 1 + 32 + 64 + 32 + 12 + 16

    /// From the sealed envelope's JSON. Nil for anything that isn't a
    /// complete version-1 x25519-aes-256-gcm-v1 envelope.
    public static func binary(fromJSON json: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["version"] as? Int == 1,
              object["scheme"] as? String == scheme,
              let ciphertext = (object["ciphertext"] as? String).flatMap({ Data(base64Encoded: $0) }),
              !ciphertext.isEmpty
        else { return nil }
        var out = Data([format])
        for field in fields {
            guard let value = (object[field.key] as? String).flatMap({ Data(base64Encoded: $0) }),
                  value.count == field.size
            else { return nil }
            out.append(value)
        }
        out.append(ciphertext)
        return out
    }

    /// Back to the sealed envelope's JSON.
    public static func json(fromBinary binary: Data) -> Data? {
        let b = [UInt8](binary)
        guard b.count > headerSize, b[0] == format else { return nil }
        var object: [String: Any] = ["version": 1, "scheme": scheme]
        var offset = 1
        for field in fields {
            object[field.key] = Data(b[offset ..< offset + field.size]).base64EncodedString()
            offset += field.size
        }
        object["ciphertext"] = Data(b[offset...]).base64EncodedString()
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// The plaintext a mesh sender seals: `0x01 ‖ raw DEFLATE(payload)`. A
/// payload is JSON, which always starts with `{`, so the marker can't be
/// mistaken for one; a receiver expands marked plaintext after decrypting
/// and passes anything else through.
public enum MeshPayload {
    static let marker: UInt8 = 0x01
    /// Inflated payloads above this are refused — a short text is well
    /// under a kilobyte, and a decompression bomb must not get far.
    static let maxExpandedSize = 64 * 1024

    public static func compress(_ payload: Data) -> Data? {
        guard let deflated = try? (payload as NSData).compressed(using: .zlib) as Data else { return nil }
        return Data([marker]) + deflated
    }

    public static func expand(_ plaintext: Data) -> Data? {
        guard plaintext.first == marker else { return plaintext }
        guard let inflated = try? (Data(plaintext.dropFirst()) as NSData).decompressed(using: .zlib) as Data,
              inflated.count <= maxExpandedSize
        else { return nil }
        return inflated
    }
}
