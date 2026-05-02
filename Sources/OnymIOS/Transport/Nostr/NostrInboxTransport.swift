import Foundation

/// Nostr-relay-backed `InboxTransport`. Each `send` builds a kind-34113
/// parameterised-replaceable event with the recipient inbox encoded as a
/// `["d", "sep-inbox:" + inbox]` tag (so relays can serve it across
/// reconnects), plus a `["t", inbox]` tag that lets clients filter by
/// kind-24113 / legacy paths. The payload goes into `content` as
/// base64. Subscribers receive every event whose `d` or `t` tag matches
/// their inbox identifier across the three filter shapes.
final class NostrInboxTransport: InboxTransport {
    private static let primaryKind = 34113
    private static let legacyKind = 24113
    private static let inboxTagPrefix = "sep-inbox:"

    private let state: State
    private let signerProvider: any NostrEphemeralSignerProvider

    init(signerProvider: any NostrEphemeralSignerProvider) {
        self.state = State()
        self.signerProvider = signerProvider
    }

    func connect(to endpoints: [TransportEndpoint]) async {
        await state.connect(to: endpoints)
    }

    func disconnect() async {
        await state.disconnect()
    }

    @discardableResult
    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        let signer = try signerProvider.makeEphemeralSigner()
        let event = try Self.buildSendEvent(payload: payload, inbox: inbox, signer: signer)
        let accepted = try await state.send(event: event)
        return PublishReceipt(messageID: event.id, acceptedBy: accepted)
    }

    /// Pure event-builder for the send path. Exposed at `internal` access
    /// so tests can verify the inbox tag set without standing up a relay.
    static func buildSendEvent(
        payload: Data,
        inbox: TransportInboxID,
        signer: NostrSigner
    ) throws -> NostrEvent {
        let tags: [[String]] = [
            ["d", inboxTagPrefix + inbox.rawValue],
            ["t", inbox.rawValue],
            ["sep_inbox", inbox.rawValue],
            ["sep_version", "1"],
        ]
        return try NostrEvent.build(
            kind: primaryKind,
            tags: tags,
            content: payload.base64EncodedString(),
            signer: signer
        )
    }

    func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream<InboundInbox> { continuation in
            Task { [state] in
                await state.subscribe(inbox: inbox, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [state] _ in
                Task { await state.unsubscribe(inbox: inbox) }
            }
        }
    }

    func unsubscribe(inbox: TransportInboxID) async {
        await state.unsubscribe(inbox: inbox)
    }

    /// Three filter shapes the subscriber installs on each relay:
    /// the primary `#d` (parameterised-replaceable) plus a `#t`
    /// fallback on the same kind, plus the legacy kind 24113 path
    /// during migration. Internal so tests can assert the shape.
    static func subscriptionFilters(inbox: String) -> [[String: Any]] {
        [
            [
                "kinds": [primaryKind],
                "#d": [inboxTagPrefix + inbox],
            ],
            [
                "kinds": [primaryKind],
                "#t": [inbox],
            ],
            [
                "kinds": [legacyKind],
                "#t": [inbox],
            ],
        ]
    }

    // MARK: - State

    fileprivate actor State {
        private var connections: [URL: NostrRelayConnection] = [:]
        private var activeSubscriptions: [TransportInboxID: Task<Void, Never>] = [:]

        func connect(to endpoints: [TransportEndpoint]) async {
            for endpoint in endpoints {
                if connections[endpoint.url] == nil {
                    let conn = NostrRelayConnection(url: endpoint.url)
                    connections[endpoint.url] = conn
                    await conn.connect()
                }
            }
        }

        func disconnect() async {
            for task in activeSubscriptions.values {
                task.cancel()
            }
            activeSubscriptions.removeAll()
            for conn in connections.values {
                await conn.disconnect()
            }
            connections.removeAll()
        }

        func send(event: NostrEvent) async throws -> Int {
            let conns = Array(connections.values)
            guard !conns.isEmpty else {
                throw TransportError.notConnected
            }
            let accepted = await withTaskGroup(of: Bool.self) { group in
                for conn in conns {
                    group.addTask {
                        do {
                            return try await conn.publishAndAwaitOK(event: event)
                        } catch {
                            return false
                        }
                    }
                }
                var count = 0
                for await ok in group where ok { count += 1 }
                return count
            }
            if accepted == 0 {
                throw TransportError.publishRejected
            }
            return accepted
        }

        func subscribe(
            inbox: TransportInboxID,
            continuation: AsyncStream<InboundInbox>.Continuation
        ) {
            activeSubscriptions[inbox]?.cancel()
            let subIDBase = "inbox-\(inbox.rawValue)"
            let filters = NostrInboxTransport.subscriptionFilters(inbox: inbox.rawValue)
            let conns = Array(connections.values)

            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for conn in conns {
                        for (index, filter) in filters.enumerated() {
                            group.addTask {
                                let filterSubID = "\(subIDBase)-\(index)"
                                let stream = await conn.subscribe(subscriptionID: filterSubID, filter: filter)
                                for await event in stream {
                                    guard !Task.isCancelled else { break }
                                    guard let payload = Data(base64Encoded: event.content) else { continue }
                                    let received = Date(timeIntervalSince1970: TimeInterval(event.displayMilliseconds) / 1000.0)
                                    continuation.yield(InboundInbox(
                                        inbox: inbox,
                                        payload: payload,
                                        receivedAt: received,
                                        messageID: event.id
                                    ))
                                }
                            }
                        }
                    }
                }
            }
            activeSubscriptions[inbox] = task
        }

        func unsubscribe(inbox: TransportInboxID) {
            activeSubscriptions[inbox]?.cancel()
            activeSubscriptions.removeValue(forKey: inbox)
        }
    }
}
