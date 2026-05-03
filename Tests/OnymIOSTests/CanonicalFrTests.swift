import XCTest
@testable import OnymIOS

/// Regression coverage for the bls12-381 canonical-Fr predicate +
/// rejection sampler that `CreateGroupInteractor` uses to mint
/// `groupID`. The contract (`sep-tyranny/src/lib.rs:299`) rejects
/// non-canonical `group_id` with `Error::InvalidCommitmentEncoding`
/// (#15); these tests pin the client-side guarantee that we never
/// hand the contract a value `>= r`.
///
/// `r = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001`
final class CanonicalFrTests: XCTestCase {

    // MARK: - isCanonicalFr boundary cases

    func test_isCanonicalFr_zero_isCanonical() {
        XCTAssertTrue(CreateGroupInteractor.isCanonicalFr([UInt8](repeating: 0, count: 32)))
    }

    func test_isCanonicalFr_one_isCanonical() {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[31] = 1
        XCTAssertTrue(CreateGroupInteractor.isCanonicalFr(bytes))
    }

    func test_isCanonicalFr_rMinusOne_isCanonical() {
        let rMinusOne: [UInt8] = [
            0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
            0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
            0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertTrue(CreateGroupInteractor.isCanonicalFr(rMinusOne))
    }

    func test_isCanonicalFr_r_isNotCanonical() {
        let r: [UInt8] = [
            0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
            0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
            0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
        ]
        XCTAssertFalse(CreateGroupInteractor.isCanonicalFr(r),
                       "the field order itself is NOT a canonical Fr")
    }

    func test_isCanonicalFr_rPlusOne_isNotCanonical() {
        let rPlusOne: [UInt8] = [
            0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
            0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
            0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x02,
        ]
        XCTAssertFalse(CreateGroupInteractor.isCanonicalFr(rPlusOne))
    }

    func test_isCanonicalFr_allOnes_isNotCanonical() {
        // The exact value that triggered the testnet failure was
        // `0xfdfb…` — same shape: high byte > 0x73 → non-canonical.
        XCTAssertFalse(CreateGroupInteractor.isCanonicalFr([UInt8](repeating: 0xFF, count: 32)))
    }

    func test_isCanonicalFr_observedFailingValue_isNotCanonical() {
        // The literal bytes from the diagnostic event in the failing
        // testnet run — kept as a regression anchor.
        let observed: [UInt8] = [
            0xfd, 0xfb, 0xc9, 0x7d, 0x06, 0x85, 0xf2, 0xb9,
            0xf3, 0xad, 0x24, 0xf7, 0xa4, 0xc7, 0x57, 0x41,
            0x6b, 0xd5, 0x3a, 0x87, 0x11, 0x47, 0x7c, 0xe2,
            0xc3, 0x59, 0x77, 0x80, 0x24, 0xdb, 0xfb, 0x0d,
        ]
        XCTAssertFalse(CreateGroupInteractor.isCanonicalFr(observed),
                       "exact value that tripped Error #15 on the v0.0.5 tyranny contract")
    }

    func test_isCanonicalFr_justBelowR_highByte0x73_isCanonical() {
        // Highest byte == 0x73 but lower bytes < r's lower bytes.
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x73
        bytes[1] = 0xec  // < 0xed at the same position
        XCTAssertTrue(CreateGroupInteractor.isCanonicalFr(bytes))
    }

    func test_isCanonicalFr_wrongLength_returnsFalse() {
        XCTAssertFalse(CreateGroupInteractor.isCanonicalFr([UInt8](repeating: 0, count: 31)))
        XCTAssertFalse(CreateGroupInteractor.isCanonicalFr([UInt8](repeating: 0, count: 33)))
    }

    // MARK: - randomCanonicalFr sampling

    func test_randomCanonicalFr_alwaysCanonical_over10kSamples() {
        // Statistically, the sampler's accept rate is `r / 2^256 ≈ 0.453`.
        // 10k samples give a generous floor on rejected-path coverage
        // (~5.5k rejections), and the assertion is unconditional.
        for _ in 0..<10_000 {
            let bytes = CreateGroupInteractor.randomCanonicalFr()
            XCTAssertEqual(bytes.count, 32)
            XCTAssertTrue(
                CreateGroupInteractor.isCanonicalFr(Array(bytes)),
                "sampler returned non-canonical bytes: \(bytes.map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

    func test_randomCanonicalFr_isNonZeroAndDistinct() {
        // Sanity: the sampler isn't returning a constant. 100 draws
        // should yield 100 distinct values with overwhelming probability.
        var seen = Set<Data>()
        for _ in 0..<100 {
            seen.insert(CreateGroupInteractor.randomCanonicalFr())
        }
        XCTAssertEqual(seen.count, 100, "sampler should not collide over 100 draws")
        XCTAssertFalse(seen.contains(Data(repeating: 0, count: 32)),
                       "all-zero would be a giveaway of a broken RNG")
    }
}
