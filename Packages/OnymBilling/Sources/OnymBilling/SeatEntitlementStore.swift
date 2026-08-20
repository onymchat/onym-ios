import CryptoKit
import Foundation

/// Where a device keeps the credentials it has been issued.
///
/// One per `(componentId, offerId)`. Stored as the broker's exact signed
/// bytes so the signature stays checkable — re-encoding would produce a
/// document that verifies only if our encoder happens to match theirs,
/// which is the failure the canonical form exists to prevent.
public protocol SeatEntitlementStoring: Sendable {
    func load() throws -> [Data]
    func save(_ rawEntitlements: [Data]) throws
}

/// File-backed, under complete protection.
public struct FileSeatEntitlementStore: SeatEntitlementStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // Same posture as the backup state store: absent is empty,
        // unreadable is an error. Reading a locked or damaged file as
        // "no entitlements" would send someone back through a purchase
        // they have already made.
        let data = try Data(contentsOf: url)
        guard let entitlements = try? JSONDecoder().decode([Data].self, from: data) else {
            throw BillingError.malformedEntitlement
        }
        return entitlements
    }

    public func save(_ rawEntitlements: [Data]) throws {
        let data = try JSONEncoder().encode(rawEntitlements)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
