import CryptoKit
import Foundation
import OnymFoundation

/// The request-bound proof of possession every `/v1/` call carries
/// (`UI-Backup-Object-HTTP.md` §8).
///
/// A holder *is* an Ed25519 public key at the operator — no account, no
/// email, no support identifier, no password. That is what makes the
/// absent reset path checkable rather than promised: there is nothing
/// for an operator to reset.
///
/// The signature covers the method, the path, and a digest of the body,
/// so a chunk upload cannot be replayed into a different index, a
/// different upload, or a different operation. Each field is length-
/// prefixed because a signature over bare concatenation can be
/// reinterpreted by shifting a boundary between two adjacent fields that
/// an attacker influences.
public enum BackupAccessProof {
    /// Domain separator, first field of every signed payload.
    static let context = "onym-backup-v1"

    public static let holderHeader = "X-Onym-Holder"
    public static let timestampHeader = "X-Onym-Timestamp"
    public static let nonceHeader = "X-Onym-Nonce"
    public static let signatureHeader = "X-Onym-Signature"

    /// The exact bytes signed, in the pinned order.
    ///
    /// The operator rebuilds this from the request it actually received
    /// — never from a client-supplied copy — so anything we get wrong
    /// here surfaces as a refusal rather than as a subtly weaker check.
    public static func signingBytes(
        method: String,
        path: String,
        holderReference: String,
        timestamp: Date,
        nonceHex: String,
        body: Data
    ) -> Data {
        var out = Data()
        appendLengthPrefixed(Data(context.utf8), to: &out)
        appendLengthPrefixed(Data(method.uppercased().utf8), to: &out)
        appendLengthPrefixed(Data(path.utf8), to: &out)
        appendLengthPrefixed(Data(holderReference.utf8), to: &out)
        appendLengthPrefixed(Data(BackupFormat.string(fromDate: timestamp).utf8), to: &out)
        appendLengthPrefixed(Data(nonceHex.utf8), to: &out)
        // The raw 32 digest bytes, not their hex — a body-less request
        // uses the digest of the empty string rather than an empty field,
        // so "no body" and "empty body" are the same signed value and
        // neither is a shorter payload an attacker could exploit.
        appendLengthPrefixed(Data(SHA256.hash(data: body)), to: &out)
        return out
    }

    /// Sign a request. Returns the header set to send with it.
    ///
    /// The nonce is not injectable from outside the package for the same
    /// reason the snapshot salt is not: a reused nonce turns a
    /// single-use proof into a replayable one. Fixtures that need a
    /// fixed value use the internal overload.
    public static func headers(
        method: String,
        path: String,
        body: Data,
        material: BackupKeyMaterial,
        now: Date = Date()
    ) throws -> [String: String] {
        try headers(method: method, path: path, body: body, material: material, now: now, nonce: nil)
    }

    static func headers(
        method: String,
        path: String,
        body: Data,
        material: BackupKeyMaterial,
        now: Date = Date(),
        nonce: Data?
    ) throws -> [String: String] {
        // Every CSPRNG call in this codebase goes through SecureRandom,
        // which throws rather than handing back a zero buffer. A
        // predictable nonce is the one thing this proof cannot survive.
        let nonceBytes = try nonce ?? SecureRandom.data(16)
        let nonceHex = nonceBytes.map { String(format: "%02x", $0) }.joined()
        // Second precision, no fractional seconds: the operator's
        // reconstruction has to produce the same string we signed, and a
        // formatter that emits milliseconds on one platform and not
        // another would fail intermittently and only for some clocks.
        let timestamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let bytes = signingBytes(
            method: method,
            path: path,
            holderReference: material.holderReference,
            timestamp: timestamp,
            nonceHex: nonceHex,
            body: body
        )
        let signature = try material.accessSigningKey.signature(for: bytes)
        return [
            holderHeader: material.holderReference,
            timestampHeader: BackupFormat.string(fromDate: timestamp),
            nonceHeader: nonceHex,
            signatureHeader: signature.base64EncodedString(),
        ]
    }

    private static func appendLengthPrefixed(_ field: Data, to out: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(field)
    }
}
