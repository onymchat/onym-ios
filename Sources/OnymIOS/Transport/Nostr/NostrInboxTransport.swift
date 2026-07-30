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
    /// Tolerance subtracted from the high-water mark when bounding a
    /// REQ's `since`, absorbing relay clock skew and out-of-order
    /// delivery. The small re-fetched overlap is deduped downstream
    /// (`SeenEventIDStore`); the point is excluding the *ancient*
    /// backlog, not being exact.
    static let replaySinceSlack: Int64 = 300

    init(
        signerProvider: any NostrEphemeralSignerProvider,
        highWaterMarks: any InboxHighWaterMarkStoring = UserDefaultsInboxHighWaterMarkStore()
    ) {
        self.state = State(highWaterMarks: highWaterMarks)
        self.signerProvider = signerProvider
    }

    func connect(to endpoints: [TransportEndpoint]) async {
        await state.connect(to: endpoints)
    }

    func disconnect() async {
        await state.disconnect()
    }

    func reconnect() async {
        await state.reconnect()
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
        // Per-stream token: this stream's termination may fire *after* a
        // newer subscription for the same inbox has been installed
        // (re-subscribe on identity rebalance / pump restart). Cleanup
        // is token-guarded so the stale termination can't tear down the
        // fresh subscription — the same race the per-generation subIDs
        // close at the relay-connection level.
        let token = UUID()
        return AsyncStream<InboundInbox> { continuation in
            Task { [state] in
                await state.subscribe(inbox: inbox, token: token, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [state] _ in
                Task { await state.unsubscribe(inbox: inbox, ifToken: token) }
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
        /// Live per-inbox subscription: the pump task plus the stream
        /// token that owns it (see `subscribe`'s token guard).
        private var activeSubscriptions: [TransportInboxID: (token: UUID, task: Task<Void, Never>)] = [:]
        /// Monotonic counter for relay subscription IDs. Each subscribe
        /// gets a unique id so an old stream's asynchronous
        /// `onTermination` CLOSE can't tear down a freshly opened REQ
        /// for the same inbox — the exact race `NostrMessageTransport`
        /// already guards against with its own generation counter.
        private var subscriptionGeneration: UInt64 = 0
        /// Per-inbox high-water marks (persisted). Read at every REQ send
        /// via the connection's `sinceProvider`, raised as events arrive.
        private let highWaterMarks: any InboxHighWaterMarkStoring

        init(highWaterMarks: any InboxHighWaterMarkStoring) {
            self.highWaterMarks = highWaterMarks
        }

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
            for entry in activeSubscriptions.values {
                entry.task.cancel()
            }
            activeSubscriptions.removeAll()
            for conn in connections.values {
                await conn.disconnect()
            }
            connections.removeAll()
        }

        /// Rebuild every connection in place. The per-connection
        /// subscription dicts survive the rebuild and their REQs replay
        /// (`since`-bounded), so consumers' AsyncStreams never break and
        /// the relay backfills exactly the gap missed while away.
        func reconnect() async {
            await withTaskGroup(of: Void.self) { group in
                for conn in connections.values {
                    group.addTask { await conn.forceReconnect() }
                }
            }
        }

        /// Per-relay publish outcome — split so the thrown error can
        /// tell "a relay answered and said no" (`publishRejected`)
        /// apart from "no relay was reachable at all" (`unreachable`,
        /// carrying the first network error's code so the app layer
        /// can explain TLS / offline / timeout to the user).
        private enum PublishOutcome {
            case accepted
            case rejected
            case failed(any Error)
        }

        func send(event: NostrEvent) async throws -> Int {
            let conns = Array(connections.values)
            guard !conns.isEmpty else {
                throw TransportError.notConnected
            }
            let outcomes = await withTaskGroup(of: PublishOutcome.self) { group in
                for conn in conns {
                    group.addTask {
                        do {
                            return try await conn.publishAndAwaitOK(event: event)
                                ? .accepted : .rejected
                        } catch {
                            return .failed(error)
                        }
                    }
                }
                var collected: [PublishOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            let accepted = outcomes.filter {
                if case .accepted = $0 { return true } else { return false }
            }.count
            if accepted > 0 { return accepted }

            let anyRejected = outcomes.contains {
                if case .rejected = $0 { return true } else { return false }
            }
            if anyRejected {
                throw TransportError.publishRejected
            }
            let firstErrorCode = outcomes.compactMap { outcome -> URLError.Code? in
                if case .failed(let error) = outcome { return (error as? URLError)?.code }
                return nil
            }.first
            throw TransportError.unreachable(firstErrorCode)
        }

        func subscribe(
            inbox: TransportInboxID,
            token: UUID,
            continuation: AsyncStream<InboundInbox>.Continuation
        ) {
            activeSubscriptions[inbox]?.task.cancel()
            subscriptionGeneration += 1
            let subID = "inbox-\(inbox.rawValue)-\(subscriptionGeneration)"
            let filters = NostrInboxTransport.subscriptionFilters(inbox: inbox.rawValue)
            let conns = Array(connections.values)
            // Bound every REQ (initial + reconnect replay) to the gap
            // since the last event already seen for this inbox. nil on
            // the first-ever run ⇒ one unbounded cold-start fetch, then
            // bounded forever. Evaluated at send time, so a reconnect
            // after hours away fetches hours — not the full history.
            let inboxTag = inbox.rawValue
            let hwm = highWaterMarks
            let sinceProvider: @Sendable () -> Int64? = {
                hwm.highWaterMark(inbox: inboxTag).map {
                    max(0, $0 - NostrInboxTransport.replaySinceSlack)
                }
            }

            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for conn in conns {
                        // One REQ carrying all three filter shapes — NOT
                        // one REQ per filter. The relay dedups events
                        // across a subscription's filters (NIP-01), and a
                        // single subscription per inbox keeps the
                        // connection well under relay
                        // `maxSubsPerConnection` caps (strfry default 20;
                        // 3 REQs per inbox tripped it on
                        // subscription-heavy devices and the overflow was
                        // silently CLOSED).
                        group.addTask {
                            let stream = await conn.subscribe(
                                subscriptionID: subID,
                                filters: filters,
                                sinceProvider: sinceProvider
                            )
                            for await event in stream {
                                guard !Task.isCancelled else { break }
                                hwm.raise(inbox: inboxTag, to: event.createdAt)
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
            activeSubscriptions[inbox] = (token: token, task: task)
        }

        /// Deliberate unsubscribe (protocol surface): unconditional.
        func unsubscribe(inbox: TransportInboxID) {
            activeSubscriptions[inbox]?.task.cancel()
            activeSubscriptions.removeValue(forKey: inbox)
        }

        /// Stream-termination cleanup: only tears down the subscription
        /// the terminating stream actually owns. A stale termination
        /// (its inbox was re-subscribed and a newer stream installed)
        /// is a no-op — without this guard the old stream's async
        /// cleanup cancelled the fresh subscription and the inbox went
        /// silently deaf.
        func unsubscribe(inbox: TransportInboxID, ifToken token: UUID) {
            guard activeSubscriptions[inbox]?.token == token else { return }
            unsubscribe(inbox: inbox)
        }
    }
}
