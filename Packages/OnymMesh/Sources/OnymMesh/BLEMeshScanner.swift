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
/// Background caveat, the main thing a device test has to measure: a
/// backgrounded app's scan is filtered to the service UUID and iOS
/// coalesces repeat sightings of the same advertiser, so a broadcaster
/// cycling fragments under one address may only get its first fragment
/// through. In the foreground duplicates are allowed and every frame is
/// seen.
public final class BLEMeshScanner: NSObject, MeshFrameSource, @unchecked Sendable {
    /// Lets iOS relaunch the app into the background for mesh frames
    /// after it was terminated for memory (not after a force-quit).
    public static let restoreIdentifier = "app.onym.mesh.listener"

    private let queue = DispatchQueue(label: "app.onym.mesh.scanner")
    private var central: CBCentralManager?
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    public override init() {
        super.init()
    }

    /// Creating the manager is what shows the Bluetooth permission
    /// prompt, so it happens on first subscription — only once the user
    /// has turned listening on — never at app launch.
    public func frames() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
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

    private func startScanning() {
        guard let central, central.state == .poweredOn, !continuations.isEmpty else { return }
        central.scanForPeripherals(
            withServices: [MeshService.uuid],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }
}

extension BLEMeshScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let frame = serviceData[MeshService.uuid]
        else { return }
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }
}
#endif
