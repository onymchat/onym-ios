import Foundation
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymMesh
import OnymTransport
import UIKit
import UserNotifications

/// App-side glue for the receive-only Bluetooth mesh (docs/mesh-ble-v1.md):
/// who this device can hear from, and what to do when it hears something.
enum MeshListening {
    /// Every (local identity, group member) pair, keyed for the mesh.
    ///
    /// The mesh delivers only from people this identity already shares a
    /// group with — a stranger has no pair key, so their frames never
    /// match. Recomputed by the transport every minute, so a new group or
    /// member starts matching without a relaunch.
    static func contacts(
        identities: IdentityRepository,
        groups: GroupRepository
    ) async -> [MeshContact] {
        let summaries = (try? await identities.currentIdentities()) ?? []
        let allGroups = await groups.currentGroups()
        var contacts: [MeshContact] = []
        for summary in summaries {
            let inbox = TransportInboxID(rawValue: InboxTag.derive(from: summary.inboxPublicKey))
            let peers = Set(
                allGroups
                    .filter { $0.ownerIdentityID == summary.id }
                    .flatMap { $0.memberProfiles.values.map(\.inboxPublicKey) }
            ).subtracting([summary.inboxPublicKey])
            for peer in peers {
                guard let pairKey = try? await identities.meshPairKey(
                    asIdentity: summary.id,
                    peerInboxPublicKey: peer
                ) else { continue }
                contacts.append(MeshContact(inbox: inbox, pairKey: pairKey))
            }
        }
        return contacts
    }

    /// A message heard over Bluetooth gets no push — it never touched a
    /// relay — so a backgrounded app raises its own notification. Content
    /// free, like the pushes: what arrived stays inside the app.
    @MainActor
    static func notifyArrival() async {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.body = String(localized: "New message")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mesh.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
