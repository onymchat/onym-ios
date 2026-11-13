#if canImport(CoreBluetooth)
import CoreBluetooth
import XCTest
@testable import OnymMesh

/// What the scanner pulls out of an advertisement — the only part of the
/// radio path that can be checked without a radio.
final class BLEMeshScannerTests: XCTestCase {
    func testReadsV1FrameFromServiceData() {
        let frame = Data([0x01, 2, 3])
        let ad: [String: Any] = [CBAdvertisementDataServiceDataKey: [MeshService.uuid: frame]]
        XCTAssertEqual(BLEMeshScanner.frame(in: ad), frame)
    }

    /// Manufacturer data arrives with the company ID in front,
    /// little-endian; the frame is what follows it.
    func testReadsCompactFrameFromManufacturerData() {
        let ad: [String: Any] = [CBAdvertisementDataManufacturerDataKey: Data([0xFF, 0xFF, 0xC1, 0x30, 0x49])]
        XCTAssertEqual(BLEMeshScanner.frame(in: ad), Data([0xC1, 0x30, 0x49]))
        let coded: [String: Any] = [CBAdvertisementDataManufacturerDataKey: Data([0xFF, 0xFF, 0xC2, 0x30, 0x49])]
        XCTAssertEqual(BLEMeshScanner.frame(in: coded), Data([0xC2, 0x30, 0x49]), "coded frames too")
    }

    func testIgnoresOtherAdvertisers() {
        XCTAssertNil(BLEMeshScanner.frame(in: [CBAdvertisementDataManufacturerDataKey: Data([0x4C, 0x00, 0xC1, 1])]), "another company")
        XCTAssertNil(BLEMeshScanner.frame(in: [CBAdvertisementDataManufacturerDataKey: Data([0xFF, 0xFF, 0x02, 1])]), "test ID, not ours")
        XCTAssertNil(BLEMeshScanner.frame(in: [CBAdvertisementDataLocalNameKey: "Headphones"]))
    }
}
#endif
