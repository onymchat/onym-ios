#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// The mesh's 128-bit service UUID. Broadcasters put it in their list of
/// service UUIDs (what iOS's scan filter matches, and the only thing a
/// backgrounded iOS scan can filter on) and key the frame's Service Data
/// with it.
public enum MeshService {
    public static let uuid = CBUUID(string: "76797324-4B57-4664-8E4D-53F4C3D38BC4")
    /// The 16-bit UUID coded frames travel under (spec §4c). Broadcasters
    /// list it as well as keying the frame's Service Data with it: the
    /// list is what a backgrounded iPhone's scan filter matches, and a
    /// 16-bit one leaves room in a legacy advertisement for the frame.
    public static let codedUUID = CBUUID(string: "4F4E")
}

/// Listens for mesh frames. Never connects, never advertises.
///
/// The one thing that could make a listener transmit is a scan request,
/// which a scanner sends only to advertisements marked scannable. Mesh
/// broadcasters are required to be non-connectable and non-scannable
/// (spec §3), so on the air this device stays silent however iOS scans.
///
/// It reads three shapes: coded frames in Service Data under the 16-bit
/// `MeshService.codedUUID` (legacy advertising, the current format;
/// spec §4c), v1 frames in the 128-bit service's Service Data (extended
/// advertising), and compact frames in Manufacturer Specific Data under
/// company `0xFFFF` (spec §4b).
///
/// In the foreground the scan is unfiltered. In the background — the
/// locked phone in a pocket — iOS allows only a scan filtered to service
/// UUIDs, which coded frames carry, and coalesces repeat sightings of
/// one advertiser into a single discovery. Broadcasters rotate their
/// address often, and the scanner restarts its scan after each frame it
/// hears while backgrounded, so the frames keep coming.
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
    /// A background scan restart is queued (see `restartSoon`).
    private var restartQueued = false

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
            withServices: backgrounded ? [MeshService.codedUUID, MeshService.uuid] : nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// A backgrounded scan reports each advertiser once; restarting it
    /// lets the next frame through. Batched, so a burst of frames costs
    /// one restart.
    private func restartSoon() {
        guard backgrounded, !restartQueued else { return }
        restartQueued = true
        queue.asyncAfter(deadline: .now() + 0.25) {
            self.restartQueued = false
            guard self.backgrounded else { return }
            self.central?.stopScan()
            self.startScanning()
        }
    }

    /// The frame an advertisement carries, if it carries one.
    static func frame(in advertisementData: [String: Any]) -> Data? {
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            if let frame = serviceData[MeshService.codedUUID], frame.first == MeshCodedFrame.kind {
                return frame
            }
            if let frame = serviceData[MeshService.uuid] {
                return frame
            }
        }
        // Manufacturer data starts with the company ID, little-endian.
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturer.count > 2,
           manufacturer[manufacturer.startIndex] == 0xFF,
           manufacturer[manufacturer.startIndex + 1] == 0xFF,
           manufacturer[manufacturer.startIndex + 2] == MeshCompactFrame.kind {
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
        restartSoon()
        MeshListenerStatus.report { $0.framesHeard += 1 }
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }
}
#endif
