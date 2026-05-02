import Foundation

/// Nostr-relay-backed `MessageTransport`. Each call to `publish` builds
/// a kind-44114 event with the topic in a `["t", topic]` tag, the payload
/// base64-encoded as `content`, and an ephemeral signer for the outer
/// pubkey so co-membership can't be inferred from the relay's view.
/// Subscribers receive every kind-44114 / kind-24114 event whose `t`
/// tag matches the topic.
final class NostrMessageTransport: MessageTransport {
    private static let primaryKind = 44114
    private static let legacyKind = 24114
    /// Default catch-up window when the caller doesn't pass `since`.
    private static let defaultCatchUp: TimeInterval = 300
    /// Tolerance applied to `since` to handle clock skew across relays.
    private static let sinceSlack: TimeInterval = 60

    private let state: State

    init() {
        self.state = State()
    }

    func connect(to endpoints: [TransportEndpoint]) async {
        await state.connect(to: endpoints)
    }

    func disconnect() async {
        await state.disconnect()
    }

    @discardableResult
    func publish(_ payload: Data, to topic: TransportTopic) async throws -> PublishReceipt {
        let signer = try OnymNostrSigner.ephemeral()
        let event = try Self.buildPublishEvent(payload: payload, topic: topic, signer: signer)
        let accepted = try await state.publish(event: event)
        return PublishReceipt(messageID: event.id, acceptedBy: accepted)
    }

    /// Pure event-builder for the publish path. Exposed at `internal`
    /// access so tests can verify Nostr framing (kind, topic tag, base64
    /// payload, valid id) without standing up a relay.
    static func buildPublishEvent(
        payload: Data,
        topic: TransportTopic,
        signer: NostrSigner
    ) throws -> NostrEvent {
        try NostrEvent.build(
            kind: primaryKind,
            tags: [["t", topic.rawValue]],
            content: payload.base64EncodedString(),
            signer: signer
        )
    }

    func subscribe(topic: TransportTopic, since: Date?) -> AsyncStream<InboundMessage> {
        let sinceUnix: Int64
        if let since {
            sinceUnix = max(0, Int64(since.timeIntervalSince1970) - Int64(Self.sinceSlack))
        } else {
            sinceUnix = Int64(Date().timeIntervalSince1970 - Self.defaultCatchUp)
        }
        return AsyncStream<InboundMessage> { continuation in
            Task { [state] in
                await state.subscribe(
                    topic: topic,
                    sinceUnix: sinceUnix,
                    kinds: [Self.primaryKind, Self.legacyKind],
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable [state] _ in
                Task { await state.unsubscribe(topic: topic) }
            }
        }
    }

    func unsubscribe(topic: TransportTopic) async {
        await state.unsubscribe(topic: topic)
    }

    // MARK: - State

    /// Owns the relay connections and per-topic subscription tasks.
    /// Separated from the outer `final class` so the concurrency-state
    /// boundary is the actor itself, not the `Sendable` adapter.
    fileprivate actor State {
        private var connections: [URL: NostrRelayConnection] = [:]
        private var activeSubscriptions: [TransportTopic: Task<Void, Never>] = [:]
        /// Monotonic counter for relay subscription IDs. Each new
        /// subscribe gets a unique id so an old stream's `onTermination`
        /// CLOSE can't kill a freshly opened REQ for the same topic.
        private var subscriptionGeneration: UInt64 = 0

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

        func publish(event: NostrEvent) async throws -> Int {
            let conns = Array(connections.values)
            guard !conns.isEmpty else {
                throw TransportError.notConnected
            }
            let accepted = await withTaskGroup(of: Bool.self) { group in
                for conn in conns {
                    group.addTask {
                        do {
                            try await conn.publish(event: event)
                            return true
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
            topic: TransportTopic,
            sinceUnix: Int64,
            kinds: [Int],
            continuation: AsyncStream<InboundMessage>.Continuation
        ) {
            activeSubscriptions[topic]?.cancel()
            subscriptionGeneration += 1
            let subID = "msg-\(topic.rawValue)-\(subscriptionGeneration)"
            let conns = Array(connections.values)

            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for conn in conns {
                        group.addTask {
                            let filter: [String: Any] = [
                                "kinds": kinds,
                                "#t": [topic.rawValue],
                                "since": sinceUnix,
                            ]
                            let stream = await conn.subscribe(subscriptionID: subID, filter: filter)
                            for await event in stream {
                                guard !Task.isCancelled else { break }
                                guard let payload = Data(base64Encoded: event.content) else { continue }
                                let received = Date(timeIntervalSince1970: TimeInterval(event.displayMilliseconds) / 1000.0)
                                continuation.yield(InboundMessage(
                                    topic: topic,
                                    payload: payload,
                                    receivedAt: received,
                                    messageID: event.id
                                ))
                            }
                        }
                    }
                }
            }
            activeSubscriptions[topic] = task
        }

        func unsubscribe(topic: TransportTopic) {
            activeSubscriptions[topic]?.cancel()
            activeSubscriptions.removeValue(forKey: topic)
        }
    }
}
