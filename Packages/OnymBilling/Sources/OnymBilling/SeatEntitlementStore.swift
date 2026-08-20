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

/// Serializes every read-modify-write of the credential store in this
/// process.
///
/// `redeem` loads, edits and saves, and every `SeatPurchaseFlow` is a
/// *fresh actor instance* built per component — so the actor isolates
/// nothing across callers. Two redeems interleaving lose one credential
/// outright: A loads, B loads, A saves, B saves over it. The lost one is
/// not recoverable, because its transaction was finished the moment it
/// was redeemed and `Transaction.updates` will not replay it.
///
/// That was survivable while redeeming happened only when somebody
/// bought something. A restore sweep that runs whenever the Device
/// Backup screen opens makes the overlap ordinary.
///
/// A process-wide lock rather than an actor, for the same reason
/// `PinnedConsentStore` uses one: the mutation is synchronous, and an
/// actor hop would force every caller async for the same guarantee. It
/// does not reach across processes.
enum SeatEntitlementStoreSerialization {
    static let lock = NSLock()
}

public extension SeatEntitlementStoring {
    /// Read, change, and write back as one step.
    ///
    /// Callers that mutate must go through this rather than pairing
    /// `load()` with `save()` themselves.
    func mutate(_ body: ([Data]) throws -> [Data]) throws {
        SeatEntitlementStoreSerialization.lock.lock()
        defer { SeatEntitlementStoreSerialization.lock.unlock() }
        try save(try body(try load()))
    }
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
