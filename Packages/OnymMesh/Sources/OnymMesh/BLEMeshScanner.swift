#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// The mesh's 128-bit service UUID. Broadcasters put it in their list of
/// service UUIDs (what iOS's scan filter matches, and the only thing a
/// backgrounded iOS scan can filter on) and key the frame's Service Data
/// with it.
public enum MeshService {
    public static let uuid = CBUUID(string: "76797324-4B57-4664-8E4D-53F4C3D38BC4")
}

/// Listens for mesh frames. Never connects, never advertises.
///
/// The one thing that could make a listener transmit is a scan request,
/// which a scanner sends only to advertisements marked scannable. Mesh
/// broadcasters are required to be non-connectable and non-scannable
/// (spec §3), so on the air this device stays silent however iOS scans.
///
/// It reads two shapes: v1 frames in the mesh service's Service Data
/// (extended advertising), and compact frames in Manufacturer Specific
/// Data under company `0xFFFF` (legacy advertising — what iPhones are
/// known to deliver; spec §4b). Seeing the second needs an unfiltered
/// scan, and iOS runs unfiltered scans only in the foreground, so in
/// the background the scan narrows to the service UUID and only v1
/// frames can arrive — and iOS coalesces repeat sightings there, so a
/// broadcaster cycling fragments may only get one through.
public final class BLEMeshScanner: NSObject, MeshFrameSource, @unchecked Sendable {
    /// Lets iOS relaunch the app into the background for mesh frames
    /// after it was terminated for memory (not after a force-quit).
    public static let restoreIdentifier = "app.onym.mesh.listener"

    private let queue = DispatchQueue(label: "app.onym.mesh.scanner")
    private var central: CBCentralManager?
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    /// Whether the scan is narrowed to the service UUID — the only scan
    /// iOS allows a backgrounded app.
    private var backgrounded = false

    public override init() {
        super.init()
    }

    /// Creating the manager is what shows the Bluetooth permission
    /// prompt, so it happens on first subscription — only once the user
    /// has turned listening on — never at app launch.
    public func frames() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        MeshListenerStatus.report { if $0.radio == .idle { $0.radio = .starting } }
        queue.async {
            self.continuations[id] = continuation
            if self.central == nil {
                self.central = CBCentralManager(
                    delegate: self,
                    queue: self.queue,
                    options: [
                        CBCentralManagerOptionShowPowerAlertKey: false,
                        CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                    ]
                )
            } else {
                self.startScanning()
            }
        }
        continuation.onTermination = { [weak self] _ in
            self?.queue.async {
                self?.continuations[id] = nil
                if self?.continuations.isEmpty == true { self?.central?.stopScan() }
            }
        }
        return stream
    }

    /// Call on entering and leaving the background: the unfiltered scan
    /// compact frames need only runs in the foreground.
    public func setBackgrounded(_ backgrounded: Bool) {
        queue.async {
            guard self.backgrounded != backgrounded else { return }
            self.backgrounded = backgrounded
            self.central?.stopScan()
            self.startScanning()
        }
    }

    private func startScanning() {
        guard let central, central.state == .poweredOn, !continuations.isEmpty else { return }
        central.scanForPeripherals(
            withServices: backgrounded ? [MeshService.uuid] : nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// The frame an advertisement carries, if it carries one.
    static func frame(in advertisementData: [String: Any]) -> Data? {
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let frame = serviceData[MeshService.uuid] {
            return frame
        }
        // Manufacturer data starts with the company ID, little-endian.
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturer.count > 2,
           manufacturer[manufacturer.startIndex] == 0xFF,
           manufacturer[manufacturer.startIndex + 1] == 0xFF,
           [MeshCompactFrame.kind, MeshCodedFrame.kind].contains(manufacturer[manufacturer.startIndex + 2]) {
            return Data(manufacturer.dropFirst(2))
        }
        return nil
    }
}

extension BLEMeshScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let radio: MeshListenerStatus.Radio
        switch central.state {
        case .poweredOn: radio = .on
        case .poweredOff: radio = .off
        case .unauthorized: radio = .unauthorized
        case .unsupported: radio = .unsupported
        case .resetting, .unknown: radio = .starting
        @unknown default: radio = .starting
        }
        MeshListenerStatus.report { $0.radio = radio }
        startScanning()
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Nothing to restore: the scanner holds no connections. Scanning
        // resumes from `centralManagerDidUpdateState`.
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let frame = Self.frame(in: advertisementData) else { return }
        MeshListenerStatus.report { $0.framesHeard += 1 }
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }
}
#endif
