import CryptoKit
import Foundation

/// A signature plus the four-byte hint naming the key that made it.
public struct DecoratedSignature: Equatable, Sendable {
    /// Last four bytes of the signer's public key. An index, never a
    /// proof — see `StellarAccountID.signatureHint`.
    public let hint: Data
    public let signature: Data

    public init(hint: Data, signature: Data) {
        self.hint = hint
        self.signature = signature
    }

    func encode(to writer: inout XDRWriter) {
        writer.writeFixedOpaque(hint)
        writer.writeVariableOpaque(signature)
    }

    static func decode(from reader: inout XDRReader) throws -> DecoratedSignature {
        let hint = try reader.readFixedOpaque(4)
        // Signature is `opaque<64>` in the schema.
        let signature = try reader.readVariableOpaque(maxCount: 64)
        return DecoratedSignature(hint: hint, signature: signature)
    }
}

/// A transaction with the signatures collected for it so far.
///
/// This is the value that travels: a proposal is an envelope with no
/// signatures, and each co-signer's contribution adds one. Stellar caps
/// an envelope at 20 signatures.
public struct TransactionEnvelope: Equatable, Sendable {
    public static let maxSignatures = 20

    public let transaction: StellarTransaction
    public private(set) var signatures: [DecoratedSignature]

    public init(transaction: StellarTransaction, signatures: [DecoratedSignature] = []) {
        self.transaction = transaction
        self.signatures = signatures
    }

    // MARK: - XDR

    public func encode(to writer: inout XDRWriter) {
        writer.writeInt32(EnvelopeType.transaction)
        transaction.encode(to: &writer)
        writer.writeArray(signatures) { $1.encode(to: &$0) }
    }

    public var xdr: Data {
        var writer = XDRWriter()
        encode(to: &writer)
        return writer.data
    }

    public var base64XDR: String { xdr.base64EncodedString() }

    public init(xdr: Data) throws {
        var reader = XDRReader(xdr)
        let type = try reader.readInt32()
        guard type == EnvelopeType.transaction else {
            // V0 envelopes are a pre-protocol-13 shape still accepted by
            // the network. Refused rather than upgraded: the two hash
            // differently, so accepting one would have this device
            // verify signatures against a hash the signer never saw.
            throw StellarError.unsupportedEnvelopeType(type)
        }
        let transaction = try StellarTransaction.decode(from: &reader)
        let signatures = try reader.readArray(maxCount: Self.maxSignatures) {
            try DecoratedSignature.decode(from: &$0)
        }
        // Trailing bytes mean the input was not exactly one envelope.
        // Tolerating them would let two readers disagree about what the
        // transaction was while both calling the input valid.
        guard reader.isAtEnd else {
            throw XDRError.trailingBytes(xdr.count)
        }
        self.transaction = transaction
        self.signatures = signatures
    }

    public init(base64XDR: String) throws {
        // `.ignoreUnknownCharacters` so an envelope pasted from a wallet
        // survives the line wrapping and stray whitespace that copying
        // through a chat app or a QR scanner introduces.
        guard let data = Data(
            base64Encoded: base64XDR.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.ignoreUnknownCharacters]
        ) else {
            throw XDRError.invalidUTF8
        }
        try self.init(xdr: data)
    }

    // MARK: - Signing

    /// Sign with `privateKey` and add the result.
    ///
    /// The hash is recomputed here from this envelope's own transaction
    /// rather than accepted from a caller: a "sign these bytes" seam
    /// would be an oracle that signs anything with a treasury key.
    public mutating func sign(
        with privateKey: Curve25519.Signing.PrivateKey,
        network: StellarNetwork
    ) throws {
        let signature = try privateKey.signature(for: transaction.hash(network: network))
        let hint = Data(privateKey.publicKey.rawRepresentation).suffix(4)
        try append(DecoratedSignature(hint: hint, signature: signature))
    }

    /// Add a signature produced elsewhere — the other device in the
    /// group, or the participant's own wallet — after checking it.
    ///
    /// Verification is against `signer`'s key and this envelope's hash,
    /// so a signature over any other transaction is refused. Callers
    /// pass the account they expect; a signature that verifies under a
    /// key nobody declared is not usable anyway, and checking it here
    /// means no call site has to remember to.
    public mutating func addSignature(
        _ signature: Data,
        from signer: StellarAccountID,
        network: StellarNetwork
    ) throws {
        guard Self.verify(
            signature: signature,
            by: signer,
            over: transaction.hash(network: network)
        ) else {
            throw StellarError.signatureDoesNotVerify
        }
        try append(DecoratedSignature(hint: signer.signatureHint, signature: signature))
    }

    /// Take the usable signatures out of an envelope that came back from
    /// an external wallet, and **nothing else**.
    ///
    /// This is the security-critical operation in the external-signing
    /// path. The returned envelope's *transaction* is discarded
    /// entirely: a wallet — or anything between it and here — could
    /// return a correctly-signed envelope for a different payment, and
    /// adopting its body would substitute that payment for the one the
    /// group approved. Only signatures survive the trip, and only those
    /// that verify against the hash **this** device computed from the
    /// proposal it already holds.
    ///
    /// `candidates` is the declared signer set. A signature verifying
    /// under none of them contributes no weight on-chain, so it is
    /// dropped rather than carried.
    ///
    /// Returns the accounts whose signatures were adopted, so a caller
    /// can say "added Alice's signature" rather than "added 1
    /// signature" — and so a return trip that yielded nothing is
    /// reported as such instead of looking like success.
    @discardableResult
    public mutating func harvestSignatures(
        from returned: TransactionEnvelope,
        candidates: [StellarAccountID],
        network: StellarNetwork
    ) -> [StellarAccountID] {
        let hash = transaction.hash(network: network)
        var adopted: [StellarAccountID] = []
        for decorated in returned.signatures {
            // The hint narrows the search; the Ed25519 check decides.
            // Signers whose hints collide are all tried — which is why
            // the "already have this one" test is by verification and
            // not by hint. Skipping on a hint match alone would drop a
            // second signer's genuine signature whenever four bytes
            // happened to collide, and its weight would never count.
            for candidate in candidates where candidate.signatureHint == decorated.hint {
                guard Self.verify(signature: decorated.signature, by: candidate, over: hash),
                      !carriesSignature(from: candidate, over: hash)
                else { continue }
                // `append` refuses past the protocol's cap, and a
                // signature that was not stored must not be reported as
                // adopted — a caller saying "added Alice's signature"
                // when the envelope is unchanged is how a proposal sits
                // a signature short with nobody able to see why.
                guard (try? append(DecoratedSignature(
                    hint: candidate.signatureHint,
                    signature: decorated.signature
                ))) != nil else { return adopted }
                adopted.append(candidate)
                break
            }
        }
        return adopted
    }

    /// Whether this envelope already carries a verifying signature from
    /// `signer`. Used to keep weight from being double-counted when the
    /// same signature arrives twice — a relay replay, or a co-signer
    /// tapping twice.
    public func hasSignature(from signer: StellarAccountID, network: StellarNetwork) -> Bool {
        let hash = transaction.hash(network: network)
        return signatures.contains { decorated in
            decorated.hint == signer.signatureHint
                && Self.verify(signature: decorated.signature, by: signer, over: hash)
        }
    }

    /// Whether a verifying signature from `signer` is already present,
    /// reusing a hash the caller has already computed. Same answer as
    /// `hasSignature(from:network:)` without re-hashing per candidate.
    private func carriesSignature(from signer: StellarAccountID, over hash: Data) -> Bool {
        signatures.contains { decorated in
            decorated.hint == signer.signatureHint
                && Self.verify(signature: decorated.signature, by: signer, over: hash)
        }
    }

    private static func verify(
        signature: Data,
        by signer: StellarAccountID,
        over hash: Data
    ) -> Bool {
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKey)
        else { return false }
        return key.isValidSignature(signature, for: hash)
    }

    /// Throws rather than silently dropping.
    ///
    /// A no-op at the cap meant `sign(with:)` could return successfully
    /// having added nothing, with no way for the caller to tell. Twenty
    /// signatures is a limit a real treasury can reach, so reaching it
    /// has to be visible.
    private mutating func append(_ signature: DecoratedSignature) throws {
        guard signatures.count < Self.maxSignatures else {
            throw StellarError.tooManySignatures(Self.maxSignatures)
        }
        signatures.append(signature)
    }
}
