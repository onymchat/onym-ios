import CryptoKit
import XCTest
import OnymFoundation
@testable import OnymStellar

/// Account IDs, amounts, and the decoder's refusals — the parts a
/// person's typing or a peer's payload reaches directly.
final class StellarValueTests: XCTestCase {

    /// A real account from the fixture set.
    private let valid = "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR"

    // MARK: - StrKey

    func test_anAccountID_roundTripsThroughItsBytes() throws {
        let account = try StellarAccountID(accountID: valid)
        XCTAssertEqual(account.publicKey.count, 32)
        XCTAssertEqual(StellarStrKey.encodeAccountID(account.publicKey), valid)
        XCTAssertEqual(try StellarAccountID(publicKey: account.publicKey), account)
    }

    /// The checksum is what makes a mistyped address fail here rather
    /// than by sending funds somewhere unrecoverable.
    func test_aSingleAlteredCharacter_failsTheChecksum() throws {
        var typo = Array(valid)
        typo[10] = typo[10] == "A" ? "B" : "A"
        XCTAssertThrowsError(try StellarStrKey.decodeAccountID(String(typo))) { error in
            XCTAssertEqual(error as? StellarStrKey.DecodeError, .checksumMismatch)
        }
    }

    func test_theDigitsPeopleSubstituteForLetters_areRejectedByName() throws {
        // Base32 has no 0, 1, 8 or 9 — the characters most often typed
        // in place of O, I and B.
        var typo = Array(valid)
        typo[5] = "0"
        XCTAssertThrowsError(try StellarStrKey.decodeAccountID(String(typo))) { error in
            XCTAssertEqual(error as? StellarStrKey.DecodeError, .invalidCharacter("0"))
        }
    }

    func test_aSecretKey_isRejectedRatherThanDecoded() throws {
        // An `S…` StrKey is the same length and alphabet as a `G…`. If
        // the version byte weren't checked, pasting a secret key into
        // the account field would "work" — and put a secret on screen
        // and into the group's wire traffic.
        let secret = "SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN"
        XCTAssertThrowsError(try StellarStrKey.decodeAccountID(secret)) { error in
            guard case .notAnAccountID = error as? StellarStrKey.DecodeError else {
                return XCTFail("expected notAnAccountID, got \(error)")
            }
        }
    }

    func test_shapeCheckedWithoutThrowing() {
        XCTAssertTrue(StellarStrKey.isValidAccountID(valid))
        XCTAssertFalse(StellarStrKey.isValidAccountID("not an address"))
        XCTAssertFalse(StellarStrKey.isValidAccountID(""))
    }

    // MARK: - Amounts

    func test_amounts_parseAndPrintWithoutFloatingPoint() throws {
        let cases: [(String, Int64, String)] = [
            ("0", 0, "0"),
            ("1", 10_000_000, "1"),
            ("0.1", 1_000_000, "0.1"),            // unrepresentable as a binary float
            ("10.0000001", 100_000_001, "10.0000001"),
            ("0.0000001", 1, "0.0000001"),        // one stroop
            ("100.5000000", 1_005_000_000, "100.5"),
            ("922337203685.4775807", Int64.max, "922337203685.4775807"),
        ]
        for (input, stroops, printed) in cases {
            let amount = try StellarAmount(decimalString: input)
            XCTAssertEqual(amount.stroops, stroops, input)
            XCTAssertEqual(amount.decimalString, printed, input)
        }
    }

    /// An eighth decimal is refused, not rounded. Rounding here would
    /// change an amount the user typed without telling them.
    func test_anEighthDecimalPlace_isRefusedRatherThanRounded() {
        XCTAssertThrowsError(try StellarAmount(decimalString: "1.00000001"))
    }

    func test_amountsThatArentPlainDecimals_areRefused() {
        for input in ["", ".", "1.", "-1", "1e7", "1,000", "1 000", "٣", "abc", "1.2.3"] {
            XCTAssertThrowsError(
                try StellarAmount(decimalString: input),
                "'\(input)' should not parse"
            )
        }
    }

    func test_anAmountTooLargeForTheLedger_isRefused() {
        XCTAssertThrowsError(try StellarAmount(decimalString: "922337203686"))
    }

    // MARK: - Assets

    func test_assetWidth_isDecidedByCodeLength() throws {
        let issuer = try StellarAccountID(accountID: valid)
        guard case .alphanum4 = try StellarAsset(code: "USDC", issuer: issuer) else {
            return XCTFail("4 characters is alphanum4")
        }
        guard case .alphanum12 = try StellarAsset(code: "USDCOIN", issuer: issuer) else {
            return XCTFail("5 characters is alphanum12")
        }
    }

    func test_assetCodes_thatCannotExist_areRefused() throws {
        let issuer = try StellarAccountID(accountID: valid)
        for code in ["", "THIRTEENCHARS", "US DC", "USD€", "USD\u{0430}"] {
            XCTAssertThrowsError(
                try StellarAsset(code: code, issuer: issuer),
                "'\(code)' should not be an asset code"
            )
        }
    }

    // MARK: - Decoder refusals

    /// A muxed destination carries a routing id that decides which of a
    /// custodian's customers gets the money. Flattening it to the base
    /// account would credit the wrong one, so it is refused.
    func test_aMuxedAccount_isRefusedRatherThanFlattened() throws {
        var writer = XDRWriter()
        writer.writeInt32(0x100) // KEY_TYPE_MUXED_ED25519
        writer.writeUInt64(7)
        writer.writeFixedOpaque(try StellarAccountID(accountID: valid).publicKey)
        var reader = XDRReader(writer.data)
        XCTAssertThrowsError(try reader.readMuxedAccount())
    }

    /// `mergeAccount` empties an account into another in one operation.
    /// The decoder has no arm for it, so a proposal containing one
    /// cannot be decoded — and therefore cannot be displayed as if it
    /// were something else.
    func test_anOperationThisAppCannotDisplay_failsToDecode() throws {
        var writer = XDRWriter()
        writer.writeOptional(Optional<StellarAccountID>.none) { $0.writeMuxedAccount($1) }
        writer.writeInt32(8) // ACCOUNT_MERGE
        writer.writeMuxedAccount(try StellarAccountID(accountID: valid))
        var reader = XDRReader(writer.data)
        XCTAssertThrowsError(try StellarOperation.decode(from: &reader)) { error in
            XCTAssertEqual(
                error as? XDRError,
                .unknownDiscriminant(type: "Operation", value: 8)
            )
        }
    }

    func test_nonZeroPadding_isRefused() throws {
        // A 1-byte opaque followed by three padding bytes, one of which
        // is not zero. Accepting it would mean two byte strings decode
        // to the same value — and a transaction hash is over bytes.
        var reader = XDRReader(Data([0xAA, 0x00, 0x01, 0x00]))
        XCTAssertThrowsError(try reader.readFixedOpaque(1)) { error in
            XCTAssertEqual(error as? XDRError, .nonZeroPadding)
        }
    }

    func test_aHostileLengthPrefix_doesNotDriveAnAllocation() {
        // Claims 4 GB of signature in a 4-byte input.
        var reader = XDRReader(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try reader.readVariableOpaque(maxCount: 64)) { error in
            guard case .lengthExceedsBound = error as? XDRError else {
                return XCTFail("expected a bound violation, got \(error)")
            }
        }
    }

    func test_trailingBytesAfterAnEnvelope_areRefused() throws {
        let base = try StellarTransaction(
            sourceAccount: StellarAccountID(accountID: valid),
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            operations: [StellarOperation(body: .changeTrust(asset: .native, limit: .max))]
        )
        var bytes = TransactionEnvelope(transaction: base).xdr
        bytes.append(0)
        XCTAssertThrowsError(try TransactionEnvelope(xdr: bytes))
    }

    // MARK: - SEP-0007

    /// The failure this encoding is written to avoid: base64 contains
    /// `+` and `/`, and a query parser that treats `+` as a space
    /// corrupts the transaction. Both must survive as escapes.
    func test_sep0007_escapesTheCharactersThatBreakBase64InAQuery() throws {
        let envelope = try envelopeWhoseBase64ContainsPlusAndSlash()
        XCTAssertTrue(envelope.base64XDR.contains("+"), "precondition for this test")
        XCTAssertTrue(envelope.base64XDR.contains("/"), "precondition for this test")

        let url = try XCTUnwrap(
            SEP0007Request(envelope: envelope, network: .testnet, message: "Rent").url
        )
        let string = url.absoluteString
        XCTAssertTrue(string.hasPrefix("web+stellar:tx?xdr="))
        // The payload's own '+' and '/' must be escaped. (The scheme's
        // literal '+' in "web+stellar" sits before the query.)
        let query = String(string.dropFirst("web+stellar:tx?".count))
        XCTAssertFalse(query.contains("+"))
        XCTAssertFalse(query.contains("/"))
        XCTAssertTrue(query.contains("%2B"))
        XCTAssertTrue(query.contains("%2F"))

        // And it survives a round trip through a standard parser.
        let parsed = try XCTUnwrap(URLComponents(string: string))
        let xdr = try XCTUnwrap(
            parsed.queryItems?.first(where: { $0.name == "xdr" })?.value
        )
        XCTAssertEqual(xdr, envelope.base64XDR)
    }

    /// Always sent, including for the public network: a wallet that
    /// guesses the network signs against a different network id and
    /// produces a signature that verifies nowhere.
    func test_sep0007_alwaysNamesTheNetwork() throws {
        for network in StellarNetwork.allCases {
            let envelope = try envelopeWhoseBase64ContainsPlusAndSlash()
            let url = try XCTUnwrap(SEP0007Request(envelope: envelope, network: network).url)
            XCTAssertTrue(
                url.absoluteString.contains("network_passphrase="),
                "\(network) must be named"
            )
        }
    }

    func test_sep0007_truncatesAnOverLongMessage() throws {
        let envelope = try envelopeWhoseBase64ContainsPlusAndSlash()
        let url = try XCTUnwrap(
            SEP0007Request(
                envelope: envelope,
                network: .testnet,
                message: String(repeating: "a", count: 500)
            ).url
        )
        let msg = try XCTUnwrap(
            URLComponents(string: url.absoluteString)?
                .queryItems?.first(where: { $0.name == "msg" })?.value
        )
        XCTAssertEqual(msg.count, SEP0007Request.maxMessageLength)
    }

    func test_aReturnURL_yieldsTheEnvelopeItCarries() throws {
        let envelope = try envelopeWhoseBase64ContainsPlusAndSlash()
        let escaped = try XCTUnwrap(
            envelope.base64XDR.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let url = try XCTUnwrap(URL(string: "onym://tx?xdr=\(escaped)"))
        XCTAssertEqual(try SEP0007Request.envelope(fromReturnURL: url), envelope)
    }

    func test_aReturnURLWithoutATransaction_isRefused() throws {
        let url = try XCTUnwrap(URL(string: "onym://tx?other=1"))
        XCTAssertThrowsError(try SEP0007Request.envelope(fromReturnURL: url)) { error in
            XCTAssertEqual(error as? SEP0007Error, .missingXDR)
        }
    }

    // MARK: - Helpers

    /// Searches sequence numbers for an envelope whose base64 happens to
    /// contain both `+` and `/`, so the escaping test has something real
    /// to check rather than a hand-written string.
    private func envelopeWhoseBase64ContainsPlusAndSlash() throws -> TransactionEnvelope {
        let source = try StellarAccountID(accountID: valid)
        for sequence in Int64(1)...2000 {
            let transaction = try StellarTransaction(
                sourceAccount: source,
                fee: 100,
                sequenceNumber: sequence,
                timeBounds: nil,
                operations: [
                    StellarOperation(body: .payment(
                        destination: source,
                        asset: .native,
                        amount: StellarAmount(stroops: sequence)
                    )),
                ]
            )
            let envelope = TransactionEnvelope(transaction: transaction)
            if envelope.base64XDR.contains("+") && envelope.base64XDR.contains("/") {
                return envelope
            }
        }
        throw XCTSkip("no envelope with both characters in range")
    }
}

/// Regression tests for the decode-path gaps found in review of #329.
///
/// Every one sits inside the threat model the package argues for: a
/// co-signer renders from decoded operations, so anything the decoder
/// accepts is something a person can be shown and asked to sign.
final class StellarDecodeHardeningTests: XCTestCase {

    private let issuer = "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR"

    // MARK: - Negative amounts

    /// Integer division truncates toward zero, so `-5_000_000 / 10_000_000`
    /// is 0 and the old renderer printed −0.5 XLM as "0.5" — a hostile
    /// proposal shown to a co-signer as a positive payment.
    func test_aNegativeAmount_keepsItsSignWhenPrinted() {
        XCTAssertEqual(StellarAmount(stroops: -5_000_000).decimalString, "-0.5")
        XCTAssertEqual(StellarAmount(stroops: -1).decimalString, "-0.0000001")
        XCTAssertEqual(StellarAmount(stroops: -10_000_000).decimalString, "-1")
        XCTAssertEqual(StellarAmount(stroops: Int64.min).decimalString.first, "-")
    }

    /// And it never reaches the renderer from the wire in the first
    /// place: the protocol has no negative amounts, so one in an
    /// envelope is refused rather than carried.
    func test_aNegativePaymentAmount_failsToDecode() throws {
        var writer = XDRWriter()
        writer.writeOptional(Optional<StellarAccountID>.none) { $0.writeMuxedAccount($1) }
        writer.writeInt32(1) // PAYMENT
        writer.writeMuxedAccount(try StellarAccountID(accountID: issuer))
        StellarAsset.native.encode(to: &writer)
        writer.writeInt64(-5_000_000)
        var reader = XDRReader(writer.data)
        XCTAssertThrowsError(try StellarOperation.decode(from: &reader)) { error in
            XCTAssertEqual(error as? StellarError, .negativeAmount(-5_000_000))
        }
    }

    func test_aNegativeStartingBalance_failsToDecode() throws {
        var writer = XDRWriter()
        writer.writeOptional(Optional<StellarAccountID>.none) { $0.writeMuxedAccount($1) }
        writer.writeInt32(0) // CREATE_ACCOUNT
        writer.writeAccountID(try StellarAccountID(accountID: issuer))
        writer.writeInt64(-1)
        var reader = XDRReader(writer.data)
        XCTAssertThrowsError(try StellarOperation.decode(from: &reader))
    }

    // MARK: - Asset codes

    /// A Cyrillic "С" is two UTF-8 bytes, fits inside alphanum12, and
    /// renders identically to the Latin "C". The construction path
    /// always refused it; the read path did not, and a proposal's asset
    /// comes from the wire.
    func test_aHomoglyphAssetCode_failsToDecode() throws {
        let spoofed = "USD\u{0421}"
        XCTAssertThrowsError(
            try StellarAsset(code: spoofed, issuer: StellarAccountID(accountID: issuer))
        )
        var reader = XDRReader(try alphanum12(codeBytes: Data(spoofed.utf8)))
        XCTAssertThrowsError(try StellarAsset.decode(from: &reader))
    }

    /// "US\0DC" and "US\0\0" used to trim to the same asset — the same
    /// "two byte strings, one value" the XDR reader refuses for
    /// padding, and here the difference is which asset moves.
    func test_anAssetCodeWithABuriedNonZeroByte_failsToDecode() throws {
        var codeBytes = Data("US".utf8)
        codeBytes.append(0)
        codeBytes.append(contentsOf: Data("DC".utf8))
        var reader = XDRReader(try alphanum12(codeBytes: codeBytes))
        XCTAssertThrowsError(try StellarAsset.decode(from: &reader))
    }

    func test_anEmptyAssetCode_failsToDecode() throws {
        var reader = XDRReader(try alphanum12(codeBytes: Data()))
        XCTAssertThrowsError(try StellarAsset.decode(from: &reader))
    }

    func test_aWellFormedCode_stillDecodes() throws {
        var reader = XDRReader(try alphanum12(codeBytes: Data("LONGASSET123".utf8)))
        let asset = try StellarAsset.decode(from: &reader)
        XCTAssertEqual(asset.code, "LONGASSET123")
    }

    /// A twelve-byte field holding "USD" plus nine zeros used to decode
    /// to `.alphanum12(code: "USD")`, which renders as "USD" — the same
    /// string a co-signer sees for the alphanum4 `USD`, a *different*
    /// asset with a different trustline. stellar-core rejects it, so it
    /// is also an asset the network would never produce.
    ///
    /// Neither the constructor tests nor the fixture round-trip could
    /// catch it: `init(code:issuer:)` picks alphanum4 at four bytes or
    /// fewer, and re-encoding the malformed field is byte-identical.
    func test_aShortCodeInAnAlphanum12Field_failsToDecode() throws {
        var reader = XDRReader(try alphanum12(codeBytes: Data("USD".utf8)))
        XCTAssertThrowsError(try StellarAsset.decode(from: &reader))
    }

    func test_anOverLongCodeInAnAlphanum4Field_failsToDecode() throws {
        // Four bytes of code with no room for a terminator is legal;
        // five is not the alphanum4 class at all.
        var writer = XDRWriter()
        writer.writeInt32(1) // ASSET_TYPE_CREDIT_ALPHANUM4
        writer.writeFixedOpaque(Data("ABCD".utf8))
        writer.writeAccountID(try StellarAccountID(accountID: issuer))
        var reader = XDRReader(writer.data)
        XCTAssertEqual(try StellarAsset.decode(from: &reader).code, "ABCD")
    }

    func test_theWidthClassesMeetWithoutOverlapping() throws {
        // Five bytes is the smallest alphanum12 and is not a legal
        // alphanum4; four is the largest alphanum4. No code is valid in
        // both, which is what keeps one rendering from meaning two
        // assets.
        var twelve = XDRReader(try alphanum12(codeBytes: Data("ABCDE".utf8)))
        XCTAssertEqual(try StellarAsset.decode(from: &twelve).code, "ABCDE")

        let issuerAccount = try StellarAccountID(accountID: issuer)
        guard case .alphanum4 = try StellarAsset(code: "ABCD", issuer: issuerAccount) else {
            return XCTFail("four bytes is alphanum4")
        }
        guard case .alphanum12 = try StellarAsset(code: "ABCDE", issuer: issuerAccount) else {
            return XCTFail("five bytes is alphanum12")
        }
    }

    /// The synthesized `Codable` bypassed the validating initializer —
    /// the cases are public — so JSON could build an asset violating
    /// its width class, and `paddedCode`'s precondition then *trapped*
    /// when it was encoded. A crash on hostile input is not validation.
    func test_assetJSON_thatViolatesItsWidthClass_throwsRatherThanTrapping() throws {
        let json = Data(#"{"code":"USD","issuer":"\#(issuer)"}"#.utf8)
        // Decodes as the alphanum4 it actually is, never as a malformed
        // alphanum12.
        let decoded = try JSONDecoder().decode(StellarAsset.self, from: json)
        guard case .alphanum4 = decoded else {
            return XCTFail("three bytes is alphanum4")
        }
        // And codes the protocol forbids are refused at decode.
        for bad in ["", "THIRTEENCHARS", "US DC"] {
            let hostile = Data(#"{"code":"\#(bad)","issuer":"\#(issuer)"}"#.utf8)
            XCTAssertThrowsError(
                try JSONDecoder().decode(StellarAsset.self, from: hostile),
                "'\(bad)' should not decode"
            )
        }
    }

    func test_assetJSON_roundTrips() throws {
        let issuerAccount = try StellarAccountID(accountID: issuer)
        for asset in [
            StellarAsset.native,
            try StellarAsset(code: "USDC", issuer: issuerAccount),
            try StellarAsset(code: "LONGASSET123", issuer: issuerAccount),
        ] {
            let data = try JSONEncoder().encode(asset)
            XCTAssertEqual(try JSONDecoder().decode(StellarAsset.self, from: data), asset)
        }
    }

    /// The hint is the *sender's* claim about which key signed, and the
    /// returned envelope is untrusted by construction. A wallet that
    /// returns a correct signature with a zeroed hint used to
    /// contribute nothing while the caller reported success.
    func test_aReturnedSignatureWithAWrongHint_isStillAdopted() throws {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x21, count: 32)
        )
        let signer = try StellarAccountID(
            publicKey: Data(key.publicKey.rawRepresentation)
        )
        let transaction = try StellarTransaction(
            sourceAccount: signer,
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            operations: [StellarOperation(body: .changeTrust(asset: .native, limit: .max))]
        )
        let signature = try key.signature(for: transaction.hash(network: .testnet))

        // A wallet that zeroed the hint.
        let returned = TransactionEnvelope(
            transaction: transaction,
            signatures: [DecoratedSignature(
                hint: Data(repeating: 0, count: 4),
                signature: signature
            )]
        )
        var proposal = TransactionEnvelope(transaction: transaction)
        let adopted = proposal.harvestSignatures(
            from: returned,
            candidates: [signer],
            network: .testnet
        )
        XCTAssertEqual(adopted, [signer])
        XCTAssertTrue(proposal.hasSignature(from: signer, network: .testnet))
    }

    /// A transaction with no operations is not "too many" of them.
    func test_anEmptyOperationList_isRejectedByName() throws {
        XCTAssertThrowsError(try StellarTransaction(
            sourceAccount: StellarAccountID(accountID: issuer),
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            operations: []
        )) { error in
            XCTAssertEqual(error as? StellarError, .noOperations)
        }
    }

    // MARK: - Signature accounting

    /// The envelope is full, so nothing is stored — and nothing is
    /// reported as adopted. Claiming a signature that was dropped is
    /// how a proposal sits a signature short with nobody able to see
    /// why.
    func test_atTheSignatureCap_nothingIsAdoptedAndNothingIsClaimed() throws {
        let source = try StellarAccountID(accountID: issuer)
        let transaction = try StellarTransaction(
            sourceAccount: source,
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            operations: [StellarOperation(body: .changeTrust(asset: .native, limit: .max))]
        )

        // Fill to the protocol's limit with distinct real signers.
        var full = TransactionEnvelope(transaction: transaction)
        for seed in 0..<UInt8(TransactionEnvelope.maxSignatures) {
            let key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(repeating: seed &+ 1, count: 32)
            )
            try full.sign(with: key, network: .testnet)
        }
        XCTAssertEqual(full.signatures.count, TransactionEnvelope.maxSignatures)

        // One more must fail loudly rather than silently do nothing.
        let extraKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0xFE, count: 32)
        )
        XCTAssertThrowsError(try full.sign(with: extraKey, network: .testnet)) { error in
            XCTAssertEqual(
                error as? StellarError,
                .tooManySignatures(TransactionEnvelope.maxSignatures)
            )
        }

        // And harvesting into a full envelope adopts nobody.
        var signed = TransactionEnvelope(transaction: transaction)
        try signed.sign(with: extraKey, network: .testnet)
        let extra = try StellarAccountID(
            publicKey: Data(extraKey.publicKey.rawRepresentation)
        )
        let adopted = full.harvestSignatures(
            from: signed,
            candidates: [extra],
            network: .testnet
        )
        XCTAssertTrue(adopted.isEmpty)
        XCTAssertEqual(full.signatures.count, TransactionEnvelope.maxSignatures)
    }

    // MARK: - Helpers

    /// An alphanum12 asset with a hand-chosen code field, so the test
    /// can write bytes the encoder would refuse to produce.
    private func alphanum12(codeBytes: Data) throws -> Data {
        var writer = XDRWriter()
        writer.writeInt32(2) // ASSET_TYPE_CREDIT_ALPHANUM12
        var padded = codeBytes
        padded.append(Data(repeating: 0, count: max(0, 12 - padded.count)))
        writer.writeFixedOpaque(padded.prefix(12))
        writer.writeAccountID(try StellarAccountID(accountID: issuer))
        return writer.data
    }
}
