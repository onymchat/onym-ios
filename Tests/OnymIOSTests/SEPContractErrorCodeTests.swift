import XCTest
@testable import OnymIOS
import OnymChain

/// A contract refusal reaches the app as a Soroban diagnostic dump, not
/// a structured field. These pin the one thing we read out of it — the
/// `Error(Contract, #N)` number — because that is what turns "the chain
/// said no" into something the UI can explain.
final class SEPContractErrorCodeTests: XCTestCase {

    /// The real body from a founder who approved a joiner seconds after
    /// creating the group, before `create_group` had been included in a
    /// ledger. Abridged in the middle; the shape around the marker is
    /// verbatim.
    private let groupNotFoundBody = """
    {"accepted":false,"message":"❌ error: transaction simulation failed: \
    HostError: Error(Contract, #5)\\n\\nEvent log (newest first):\\n   \
    0: [Diagnostic Event] contract:CAFX4A2KLOK7RE5QSPTDQ3UBCWOUSBPPFC2PU7M6ZP53GPGRCL67HNR3, \
    topics:[error, Error(Contract, #5)], data:\\\\\\"escalating Ok(ScErrorType::Contract) \
    frame-exit to Err\\\\\\"\\n   1: [Diagnostic Event] topics:[fn_call, \
    CAFX4A2KLOK7RE5QSPTDQ3UBCWOUSBPPFC2PU7M6ZP53GPGRCL67HNR3, update_commitment]"}
    """

    func test_readsTheContractErrorNumberOutOfADiagnosticDump() {
        XCTAssertEqual(
            SEPContractErrorCode.parse(fromDiagnostics: groupNotFoundBody),
            SEPContractErrorCode.groupNotFound.rawValue
        )
    }

    func test_theCodeIsReachableThroughTheTransportError() {
        let error = SEPError.invalidResponse(statusCode: 502, body: groupNotFoundBody)
        XCTAssertEqual(error.contractErrorCode, 5)
    }

    /// The numbers are a wire contract with `onym-contracts`; a silent
    /// renumbering here would mis-explain every failure.
    func test_codesMatchTheContractsEnum() {
        XCTAssertEqual(SEPContractErrorCode.notInitialized.rawValue, 1)
        XCTAssertEqual(SEPContractErrorCode.groupAlreadyExists.rawValue, 4)
        XCTAssertEqual(SEPContractErrorCode.groupNotFound.rawValue, 5)
        XCTAssertEqual(SEPContractErrorCode.invalidProof.rawValue, 7)
        XCTAssertEqual(SEPContractErrorCode.publicInputsMismatch.rawValue, 10)
        XCTAssertEqual(SEPContractErrorCode.proofReplay.rawValue, 12)
        XCTAssertEqual(SEPContractErrorCode.adminOnly.rawValue, 14)
    }

    func test_multiDigitCodesAreNotTruncated() {
        let body = "HostError: Error(Contract, #15) something something"
        XCTAssertEqual(SEPContractErrorCode.parse(fromDiagnostics: body), 15)
    }

    /// Text-matching a diagnostic is best-effort by nature. A miss must
    /// answer `nil` so the caller falls back to showing the raw message
    /// rather than confidently mislabelling it.
    func test_aBodyWithoutTheMarkerYieldsNothing() {
        XCTAssertNil(SEPContractErrorCode.parse(fromDiagnostics: "connection reset by peer"))
        XCTAssertNil(SEPContractErrorCode.parse(fromDiagnostics: ""))
        XCTAssertNil(SEPContractErrorCode.parse(fromDiagnostics: "Error(Contract, #)"))
    }

    func test_decodeFailuresCarryNoContractCode() {
        XCTAssertNil(SEPError.decodeFailure("bad json").contractErrorCode)
    }
}
