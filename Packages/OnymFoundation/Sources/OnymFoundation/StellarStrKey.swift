import Foundation

/// Stellar StrKey encoding (SEP-0023).
/// Encodes Ed25519 public keys as G... account IDs.
///
/// Ported verbatim from `stellar-mls/clients/ios/StellarChat/Models/StellarStrKey.swift`
/// to avoid a full Stellar SDK dependency for one tiny encoder.
public enum StellarStrKey {
    /// Version byte for Ed25519 public key (account ID): 6 << 3 = 48.
    private static let versionAccountID: UInt8 = 6 << 3

    /// Encode a 32-byte Ed25519 public key as a Stellar account ID (G...).
    public static func encodeAccountID(_ publicKey: Data) -> String {
        precondition(publicKey.count == 32, "Ed25519 public key must be 32 bytes")
        var payload = Data([versionAccountID])
        payload.append(publicKey)
        let checksum = crc16XModem(payload)
        payload.append(checksum.littleEndianBytes)
        return base32Encode(payload)
    }

    // MARK: - CRC16-XModem

    private static func crc16XModem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc & 0xFFFF
    }

    // MARK: - Base32 (RFC 4648, no padding)

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32Encode(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt64 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(base32Alphabet[index])
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(base32Alphabet[index])
        }

        return result
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

// MARK: - Decoding

public extension StellarStrKey {
    /// Why a `G…` string could not be read as an account ID. Cases are
    /// distinct because the treasury's account field surfaces them to
    /// someone pasting an address, and "that isn't 56 characters" and
    /// "the checksum says you dropped a character" are different
    /// instructions to the person typing.
    enum DecodeError: Error, Equatable, Sendable {
        /// Not 56 characters, so it cannot be a StrKey account ID
        /// regardless of content.
        case wrongLength(Int)
        /// A character outside the RFC 4648 base32 alphabet. StrKey is
        /// uppercase-only and has no `0`, `1`, `8`, or `9` — the digits
        /// people most often substitute for `O`, `I`, and `B`.
        case invalidCharacter(Character)
        /// Right shape, wrong version byte: a seed (`S…`), a contract
        /// (`C…`), a muxed account (`M…`), or something else entirely.
        /// Carries the byte so a caller can say which.
        case notAnAccountID(UInt8)
        /// The CRC16 doesn't match the payload — a typo or a truncated
        /// paste. This is the check that makes a `G…` self-validating,
        /// and the reason a mistyped address is caught here rather than
        /// by a failed transaction.
        case checksumMismatch
    }

    /// Decode a Stellar account ID (`G…`) to its 32-byte Ed25519 public
    /// key. The inverse of `encodeAccountID`.
    ///
    /// Deliberately strict: no whitespace trimming, no case folding, no
    /// muxed (`M…`) support. Callers normalize before calling, because a
    /// decoder that silently repairs its input cannot also be the thing
    /// that tells a user their address is wrong. Muxed accounts are
    /// rejected rather than unwrapped — they carry a memo ID this app
    /// has nowhere to put, and dropping it would send funds to the right
    /// account with the wrong routing.
    static func decodeAccountID(_ strKey: String) throws -> Data {
        guard strKey.count == 56 else {
            throw DecodeError.wrongLength(strKey.count)
        }
        let decoded = try base32Decode(strKey)
        // 1 version + 32 key + 2 checksum. Guaranteed by the 56-char
        // check above (56 × 5 = 280 bits = 35 bytes exactly, which is
        // why account IDs carry no base32 padding), asserted so a future
        // change to either constant can't silently disagree.
        guard decoded.count == 35 else {
            throw DecodeError.wrongLength(strKey.count)
        }
        let version = decoded[0]
        guard version == versionAccountID else {
            throw DecodeError.notAnAccountID(version)
        }
        let payload = decoded.prefix(33)
        let expected = crc16XModem(Data(payload))
        let actual = UInt16(decoded[33]) | (UInt16(decoded[34]) << 8)
        guard expected == actual else {
            throw DecodeError.checksumMismatch
        }
        return Data(decoded[1..<33])
    }

    /// Whether `strKey` is a well-formed account ID, checksum included.
    /// The shape check a text field wants, without a `try?` at the call
    /// site pretending an error was considered.
    static func isValidAccountID(_ strKey: String) -> Bool {
        (try? decodeAccountID(strKey)) != nil
    }

    private static func base32Decode(_ input: String) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 5 / 8)
        var buffer: UInt64 = 0
        var bitsLeft = 0
        for character in input {
            guard let index = base32Alphabet.firstIndex(of: character) else {
                throw DecodeError.invalidCharacter(character)
            }
            buffer = (buffer << 5) | UInt64(index)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                out.append(UInt8((buffer >> UInt64(bitsLeft)) & 0xFF))
            }
        }
        // Leftover bits are the encoder's zero padding; for a 35-byte
        // payload there are none. Any set bit here would mean the string
        // encodes something other than whole bytes, which `count == 35`
        // above already rules out.
        return out
    }
}
