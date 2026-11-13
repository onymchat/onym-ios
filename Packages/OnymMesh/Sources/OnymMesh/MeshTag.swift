import CryptoKit
import Foundation

/// The mesh's addressing, built so that nobody listening on the radio
/// can tell who a broadcast is for (spec: `docs/mesh-ble-v1.md`).
///
/// A frame never names its recipient. It carries a short tag that only
/// the sender and the recipient can compute — from a key the two of
/// them share and nobody else can derive, not even someone holding the
/// recipient's public inbox key (which is in every share-my-key QR) —
/// and the tag changes every epoch, so today's frames can't be linked
/// to tomorrow's.
public enum MeshEpoch {
    /// 15 minutes. Short enough that a tag says little for long; long
    /// enough that phones whose clocks disagree by minutes still agree
    /// on the epoch most of the time (receivers also accept neighbours).
    public static let length: TimeInterval = 15 * 60

    public static func number(at date: Date) -> UInt32 {
        let n = (date.timeIntervalSince1970 / length).rounded(.down)
        return UInt32(clamping: Int64(max(0, n)))
    }
}

/// The secret one pair of inbox keys shares for the mesh.
///
/// X25519 is symmetric — `X25519(a, B) == X25519(b, A)` — so either side
/// derives the same key from its own private key and the other's public
/// key. HKDF separates it from the inbox key's other use (sealing
/// envelopes), so a mesh key reveals nothing about either.
public enum MeshPairKey {
    static let salt = Data("onym-mesh-pair-v1".utf8)

    public static func derive(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data
    ) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// A frame's recipient tag for one epoch: the first three bytes of
/// `HMAC-SHA256(pairKey, "onym-mesh-tag-v1" ‖ epoch)`.
///
/// Three bytes on purpose. Unrelated frames collide with a receiver's
/// tags often enough that matching one says little about the receiver,
/// and a collision costs one failed decrypt — the envelope authenticates
/// its sender, so a false match is discarded, never misdelivered.
public struct MeshTag: Hashable, Sendable {
    public static let byteCount = 3
    static let domain = Data("onym-mesh-tag-v1".utf8)

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    /// Lowercase hex, for logs.
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public static func derive(pairKey: Data, epoch: UInt32) -> MeshTag {
        var message = domain
        message.append(contentsOf: withUnsafeBytes(of: epoch.bigEndian) { Array($0) })
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: pairKey))
        return MeshTag(bytes: Data(mac.prefix(byteCount)))!
    }
}
