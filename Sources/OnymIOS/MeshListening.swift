import Foundation
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymInbox
import OnymMesh
import OnymTransport
import UIKit
import UserNotifications

/// App-side glue for the receive-only Bluetooth mesh (docs/mesh-ble-v1.md):
/// who this device can hear from, and what to do when it hears something.
enum MeshListening {
    /// Follow the Settings switch for the life of the app: on starts a
    /// listener (the Bluetooth permission prompt appears right then, the
    /// first time), off stops it. Never returns until cancelled.
    static func follow(
        identities: IdentityRepository,
        groups: GroupRepository,
        dispatcher: IncomingMessageDispatcher
    ) async {
        var listening: Task<Void, Never>?
        for await enabled in MeshListeningPreference.values() {
            listening?.cancel()
            listening = nil
            await MainActor.run { MeshListenerStatus.shared.reset() }
            if enabled {
                listening = Task {
                    await listen(identities: identities, groups: groups, dispatcher: dispatcher)
                }
            }
        }
        listening?.cancel()
    }

    /// One listening session: scanner → receive-only transport → fan-out
    /// into the dispatcher, until cancelled.
    private static func listen(
        identities: IdentityRepository,
        groups: GroupRepository,
        dispatcher: IncomingMessageDispatcher
    ) async {
        let scanner = BLEMeshScanner()
        let observers = await followAppState(scanner)
        let transport = MeshInboxTransport(
            source: scanner,
            contacts: { await contacts(identities: identities, groups: groups) }
        )
        await transport.connect(to: [])
        await InboxFanoutInteractor(
            inboxTransport: transport,
            identityRepository: identities,
            dispatcher: dispatcher
        ).run()
        await transport.disconnect()
        await MainActor.run { observers.forEach(NotificationCenter.default.removeObserver) }
    }

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

    /// Narrow the scan when the app backgrounds and widen it again on
    /// return: compact frames need the unfiltered scan iOS allows only in
    /// the foreground. Keep the returned observers alive.
    @MainActor
    static func followAppState(_ scanner: BLEMeshScanner) -> [NSObjectProtocol] {
        scanner.setBackgrounded(UIApplication.shared.applicationState == .background)
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                scanner.setBackgrounded(true)
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                scanner.setBackgrounded(false)
            },
        ]
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
