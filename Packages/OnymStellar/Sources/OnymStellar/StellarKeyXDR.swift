import Foundation

/// `AccountID` and `MuxedAccount` XDR, kept together because they look
/// alike and are not interchangeable.
///
///     union PublicKey switch (PublicKeyType type) {
///     case PUBLIC_KEY_TYPE_ED25519: uint256 ed25519;
///     };
///     typedef PublicKey AccountID;
///
///     union MuxedAccount switch (CryptoKeyType type) {
///     case KEY_TYPE_ED25519:       uint256 ed25519;
///     case KEY_TYPE_MUXED_ED25519: struct { uint64 id; uint256 ed25519; };
///     };
///
/// Both spell an unmuxed Ed25519 account as discriminant `0` followed by
/// 32 bytes, so the same bytes decode under either reader — but the
/// schema picks one per field and a transaction hash is over bytes, so
/// using the wrong one produces a valid-looking envelope nobody can
/// countersign. The schema's choice is named at each call site rather
/// than inferred.
public extension XDRWriter {
    /// `AccountID`. Used where the schema forbids muxing: `createAccount`
    /// destinations, asset issuers, signer keys.
    mutating func writeAccountID(_ account: StellarAccountID) {
        writeInt32(0) // PUBLIC_KEY_TYPE_ED25519
        writeFixedOpaque(account.publicKey)
    }

    /// `MuxedAccount`, always written unmuxed. This app never constructs
    /// a muxed account: the multiplexing id is a routing hint for
    /// custodians, and `StellarStrKey.decodeAccountID` refuses `M…`
    /// addresses at the boundary, so there is nowhere for one to enter.
    mutating func writeMuxedAccount(_ account: StellarAccountID) {
        writeInt32(0) // KEY_TYPE_ED25519
        writeFixedOpaque(account.publicKey)
    }
}

public extension XDRReader {
    mutating func readAccountID() throws -> StellarAccountID {
        let type = try readInt32()
        guard type == 0 else {
            throw XDRError.unknownDiscriminant(type: "PublicKey", value: type)
        }
        return try StellarAccountID(publicKey: readFixedOpaque(32))
    }

    /// Reads only the unmuxed arm. A muxed account is rejected rather
    /// than flattened to its underlying address: the id it carries is
    /// how the receiving custodian routes the funds to the right
    /// customer, and dropping it would credit the wrong one.
    mutating func readMuxedAccount() throws -> StellarAccountID {
        let type = try readInt32()
        switch type {
        case 0: // KEY_TYPE_ED25519
            return try StellarAccountID(publicKey: readFixedOpaque(32))
        default: // includes KEY_TYPE_MUXED_ED25519 (0x100)
            throw XDRError.unknownDiscriminant(type: "MuxedAccount", value: type)
        }
    }
}
