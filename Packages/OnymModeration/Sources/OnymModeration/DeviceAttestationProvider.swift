import Foundation
import DeviceCheck

/// Seam over the platform's device-attestation token source. The
/// token proves "this app on this physical device" to the enforcement
/// backend, which is the only party that can query Apple for the
/// device's mark bits (the DeviceCheck key never ships in the app).
public protocol DeviceAttestationProvider: Sendable {
    /// False on the simulator and enterprise-signed builds
    /// (profile §8.5). Callers must degrade toward
    /// gate-check-required, never toward unmoderated operation.
    var isSupported: Bool { get }
    /// A fresh, ephemeral, unlinkable DeviceCheck token. Throws
    /// `ModerationError.attestationUnavailable` when unsupported.
    func generateToken() async throws -> Data
}

/// Production provider over `DCDevice`. Tokens are single-use and
/// carry no device identifier — linkage to an enrollment exists only
/// while (identity signature, token) travel together in one session
/// (profile §5).
public struct DCDeviceAttestationProvider: DeviceAttestationProvider {
    public init() {}

    public var isSupported: Bool {
        DCDevice.current.isSupported
    }

    public func generateToken() async throws -> Data {
        guard isSupported else {
            throw ModerationError.attestationUnavailable
        }
        return try await DCDevice.current.generateToken()
    }
}
