import Foundation
import os.log

/// Persistent WebSocket connection to a single Nostr relay. Owns the
/// REQ/EVENT/EOSE/OK/CLOSED framing and is the only place in the
/// transport layer that touches `URLSessionWebSocketTask`.
///
/// Lifecycle is a small state machine (see `docs`/reconnect design):
///
/// ```
///             connect()                first frame received
/// Disconnected ────────► Connecting ─────────────────────► Live
///      ▲                     │ receive() throws /             │
///      │                     │ repeated CLOSED /              │ staleness /
///      │    backoff sleep    ▼ probe failure                  │ receive() throws /
///      └────────────────── Backoff ◄───────────────────────────┘ forceReconnect()
///          (attempts++; reset only on entering Live)
/// ```
///
/// Key invariants:
///  - Every (re)connect bumps `connectionGeneration`; the receive loop,
///    liveness monitor, and failure funnel all no-op when superseded, so
///    overlapping reconnects can never leave two loops fighting over the
///    same socket.
///  - The connection is *confirmed live* only when a frame actually
///    arrives — `reconnectAttempts` resets there, never in `connect()`,
///    so backoff escalates across genuinely failing attempts (capped at
///    `maxReconnectDelay`, default 30 s).
///  - A subscription is one `REQ` carrying *all* of its filters (NIP-01
///    dedups within a subscription) — never one REQ per filter, which
///    multiplied subscription count 3× and tripped relay
///    `maxSubsPerConnection` caps.
///  - `CLOSED` is handled, not ignored: first CLOSED for a live
///    subscription re-REQs it once; a repeat within the same connection
///    generation treats the connection as unhealthy and rebuilds. A
///    relay-side subscription rejection is therefore visible and
///    recoverable instead of silent deafness.
///  - Prolonged silence is death: the liveness monitor probes with a
///    match-nothing REQ (the relay's immediate EOSE is a pong stand-in;
///    verified against nostr.onym.app) and rebuilds when no frame lands
///    within `livenessTimeout`. A half-open socket — where `receive()`
///    hangs forever and never throws — cannot stay deaf.
actor NostrRelayConnection {
    let url: URL
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    /// Live subscriptions: subID → (filters, per-event callback). All of
    /// a subscription's filters ship in one REQ frame.
    private var subscriptions: [String: (filters: [[String: Any]], callback: (NostrEvent) -> Void)] = [:]
    private(set) var isConnected = false
    private var reconnectAttempts = 0
    private var pendingOKContinuations: [String: CheckedContinuation<Bool, any Error>] = [:]
    private var livenessTask: Task<Void, Never>?
    private var onOKCallback: ((String, Bool) -> Void)?
    /// Bumped on every `connect()`/`disconnect()`/`forceReconnect()`.
    private var connectionGeneration: UInt64 = 0
    /// Wall-clock time of the last frame received on the current socket.
    private var lastActivityAt = Date()
    /// Subscription ids already re-REQ'd after a CLOSED in the current
    /// generation. A second CLOSED for the same id escalates to a rebuild.
    private var closedRetriedSubIDs: Set<String> = []

    func setOnOK(_ callback: @escaping (String, Bool) -> Void) {
        onOKCallback = callback
    }

    // Timings — injectable so the (otherwise minute-scale) liveness and
    // backoff paths are exercisable in tests. Defaults are production
    // values.
    /// How often the liveness monitor probes the relay and checks for
    /// staleness.
    private let pingInterval: TimeInterval
    /// No frame within this window ⇒ the socket is treated as dead and
    /// rebuilt. Must comfortably exceed `pingInterval` so a healthy
    /// relay's probe reply (EOSE) keeps the connection alive.
    private let livenessTimeout: TimeInterval
    private let baseReconnectDelay: TimeInterval
    /// Backoff cap. Deliberately modest: minute-scale retry gaps read as
    /// "the app is dead" to a user mid-conversation.
    private let maxReconnectDelay: TimeInterval
    private static let connectionTimeout: TimeInterval = 15
    private static let publishTimeout: TimeInterval = 5
    /// Subscription id for the liveness probe. A REQ under this id with a
    /// filter matching nothing draws an immediate EOSE from a conformant
    /// relay — our stand-in for a WebSocket pong (sendPing is avoided:
    /// CFNetwork's pong handler has a known crash where it fires on an
    /// internal queue after the task is cancelled and dereferences a
    /// freed nw_connection).
    private static let livenessSubID = "__onym_hb"

    init(
        url: URL,
        pingInterval: TimeInterval = 20,
        livenessTimeout: TimeInterval = 55,
        baseReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 30
    ) {
        self.url = url
        self.pingInterval = pingInterval
        self.livenessTimeout = livenessTimeout
        self.baseReconnectDelay = baseReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = Self.connectionTimeout
        // Long-lived WebSocket: no wall-clock resource bound. Death is
        // detected by the liveness monitor, not the URL loader. (A finite
        // bound would force periodic full-history replays until the
        // since-bounded replay of the next PR lands; revisit there.)
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)
    }

    func connect() {
        guard webSocketTask == nil else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        closedRetriedSubIDs.removeAll()
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        isConnected = true
        // NB: `reconnectAttempts` is NOT reset here — connecting is an
        // attempt, not a confirmed-live connection. It resets on the
        // first frame received (see `receiveLoop`), so backoff escalates
        // across a run of failed attempts against a dead relay.
        lastActivityAt = Date()
        Task { await receiveLoop(generation: generation) }
        startLivenessMonitor(generation: generation)

        for (subID, entry) in subscriptions {
            sendREQ(subscriptionID: subID, filters: entry.filters)
        }

        // URLSessionWebSocketTask exposes no reliable onOpen callback.
        // Replay subscriptions shortly after connect so filters added
        // during the handshake window are not lost if the initial send
        // happened too early.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            await self.replaySubscriptions(generation: generation)
        }
    }

    func disconnect() {
        // Supersede any in-flight receive loop / liveness monitor.
        connectionGeneration &+= 1
        livenessTask?.cancel()
        livenessTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        reconnectAttempts = 0
    }

    /// Tear down the current socket and rebuild it immediately,
    /// re-issuing every live subscription's REQ. Unconditional by design:
    /// this is the app-driven refresh (foreground, regained
    /// connectivity), and a fresh REQ is the only mechanism that
    /// backfills events missed while the socket was dead or suspended —
    /// probing first and skipping the rebuild on a healthy-*looking*
    /// socket provably loses messages (design doc F3).
    func forceReconnect() {
        connectionGeneration &+= 1
        livenessTask?.cancel()
        livenessTask = nil
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        connect()
    }

    func publish(event: NostrEvent) async throws {
        let frame: [Any] = ["EVENT", event.jsonObject]
        let data = try JSONSerialization.data(withJSONObject: frame)
        let string = String(data: data, encoding: .utf8)!
        guard let task = webSocketTask else {
            throw URLError(.notConnectedToInternet)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await task.send(.string(string))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.publishTimeout))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Publish and wait for the relay's `OK` for this event id. Returns
    /// `true` on `OK true`, treats a 5-second silence as acceptance to
    /// avoid hanging on relays that drop OKs. The continuation is stored
    /// before the send so a fast OK can never be missed.
    func publishAndAwaitOK(event: NostrEvent) async throws -> Bool {
        let eventID = event.id

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            self.pendingOKContinuations[eventID] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.timeoutPendingOK(eventID: eventID)
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.publish(event: event)
                } catch {
                    await self.failPendingOK(eventID: eventID, error: error)
                }
            }
        }
    }

    private func timeoutPendingOK(eventID: String) {
        if let continuation = pendingOKContinuations.removeValue(forKey: eventID) {
            continuation.resume(returning: true)
        }
    }

    private func failPendingOK(eventID: String, error: any Error) {
        if let continuation = pendingOKContinuations.removeValue(forKey: eventID) {
            continuation.resume(throwing: error)
        }
    }

    /// Open one relay subscription carrying every filter in `filters`
    /// (single REQ frame — the relay dedups events across the filters
    /// within one subscription, NIP-01).
    func subscribe(
        subscriptionID: String,
        filters: [[String: Any]]
    ) -> AsyncStream<NostrEvent> {
        let stream = AsyncStream<NostrEvent> { continuation in
            subscriptions[subscriptionID] = (filters, { event in
                continuation.yield(event)
            })
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.unsubscribe(subscriptionID: subscriptionID)
                }
            }
        }
        sendREQ(subscriptionID: subscriptionID, filters: filters)
        return stream
    }

    func unsubscribe(subscriptionID: String) {
        subscriptions.removeValue(forKey: subscriptionID)
        let frame: [Any] = ["CLOSE", subscriptionID]
        if let data = try? JSONSerialization.data(withJSONObject: frame),
           let string = String(data: data, encoding: .utf8)
        {
            Task { try? await webSocketTask?.send(.string(string)) }
        }
    }

    // MARK: - Private

    private func sendREQ(subscriptionID: String, filters: [[String: Any]]) {
        var frame: [Any] = ["REQ", subscriptionID]
        frame.append(contentsOf: filters)
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let string = String(data: data, encoding: .utf8)
        else { return }
        Task { try? await webSocketTask?.send(.string(string)) }
    }

    private func replaySubscriptions(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        for (subID, entry) in subscriptions {
            sendREQ(subscriptionID: subID, filters: entry.filters)
        }
    }

    private func receiveLoop(generation: UInt64) async {
        while generation == connectionGeneration {
            guard let task = webSocketTask else { return }
            do {
                let message = try await task.receive()
                lastActivityAt = Date()
                // A frame arrived — the connection is confirmed live.
                // This (and only this) resets the backoff counter.
                reconnectAttempts = 0
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                handleMessage(text, generation: generation)
            } catch {
                await handleConnectionFailure(generation: generation)
                return
            }
        }
    }

    /// Single funnel for "this socket is dead, rebuild it". Guarded by
    /// the connection generation so a stale receive loop or liveness
    /// monitor firing after a newer connect() is a no-op. Sleeps out the
    /// backoff (escalating only while no frame has confirmed the
    /// connection live) before reconnecting.
    private func handleConnectionFailure(generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        livenessTask?.cancel()
        livenessTask = nil
        isConnected = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        reconnectAttempts += 1
        let delay = min(
            maxReconnectDelay,
            baseReconnectDelay * pow(2.0, Double(min(reconnectAttempts - 1, 6)))
        )
        try? await Task.sleep(for: .seconds(delay))
        guard generation == connectionGeneration else { return }
        connect()
    }

    /// Active liveness monitor. Once per `pingInterval`:
    ///
    ///  1. **Detect a half-open socket.** If no frame has arrived within
    ///     `livenessTimeout` the connection is silently dead — the OS
    ///     still thinks it's open, `receive()` never throws, and the
    ///     error-path reconnect never fires. Rebuild.
    ///  2. **Keep the socket provably alive.** Send the match-nothing
    ///     probe REQ; a conformant relay's immediate EOSE lands in the
    ///     receive loop and refreshes `lastActivityAt`. If the send
    ///     itself throws, the socket is dead now — rebuild.
    ///
    /// Fail-closed: a nil or non-running task also routes to the failure
    /// funnel — this is the one component whose job is to catch what the
    /// error path missed, so it never silently stops.
    private func startLivenessMonitor(generation: UInt64) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled, let self else { break }
                let alive = await self.livenessTick(generation: generation)
                if !alive { break }
            }
        }
    }

    /// One liveness cycle. Returns `false` when this monitor should stop:
    /// superseded by a newer generation (no-op), or it routed a dead
    /// socket into the failure funnel (which spawns a fresh monitor).
    private func livenessTick(generation: UInt64) async -> Bool {
        guard generation == connectionGeneration else { return false }

        guard let task = webSocketTask, task.state == .running else {
            await handleConnectionFailure(generation: generation)
            return false
        }

        if Date().timeIntervalSince(lastActivityAt) > livenessTimeout {
            await handleConnectionFailure(generation: generation)
            return false
        }

        // A single-id filter for a valid but nonexistent (all-zero) event
        // id matches nothing: immediate EOSE, no live events. Kept plain
        // (no `limit`, no exotic keys) so strict relays accept it.
        let probe = "[\"REQ\",\"\(Self.livenessSubID)\",{\"ids\":[\"\(String(repeating: "0", count: 64))\"]}]"
        do {
            try await task.send(.string(probe))
            return true
        } catch {
            await handleConnectionFailure(generation: generation)
            return false
        }
    }

    /// Reject incoming frames over 1 MB so a malicious relay can't
    /// exhaust memory.
    private static let maxMessageSize = 1_048_576
    private static let securityLogger = Logger(subsystem: "app.onym.ios", category: "Transport")

    private func handleMessage(_ text: String, generation: UInt64) {
        guard text.utf8.count <= Self.maxMessageSize else {
            Self.securityLogger.warning("Relay oversized message rejected (\(text.utf8.count) bytes): \(self.url.absoluteString, privacy: .public)")
            return
        }
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let kind = array.first as? String
        else { return }

        switch kind {
        case "EVENT":
            guard array.count >= 3,
                  let subID = array[1] as? String,
                  let eventObj = array[2] as? [String: Any]
            else { return }
            if let event = parseEvent(eventObj),
               let entry = subscriptions[subID]
            {
                entry.callback(event)
            }
        case "EOSE":
            break
        case "OK":
            if array.count >= 3,
               let eventID = array[1] as? String,
               let accepted = array[2] as? Bool {
                if let continuation = pendingOKContinuations.removeValue(forKey: eventID) {
                    continuation.resume(returning: accepted)
                }
                onOKCallback?(eventID, accepted)
            }
        case "CLOSED":
            // The relay rejected or terminated one of our subscriptions
            // (e.g. a `maxSubsPerConnection` cap). Ignoring this frame is
            // silent permanent deafness on that inbox — the failure mode
            // behind "messages stop arriving until relaunch" on
            // subscription-heavy devices. Retry the REQ once; a repeat
            // for the same sub in this generation means the condition is
            // persistent, so rebuild the connection and let the normal
            // failure/backoff path own it.
            guard array.count >= 2, let subID = array[1] as? String else { return }
            guard subID != Self.livenessSubID else { return }
            guard let entry = subscriptions[subID] else { return }
            if closedRetriedSubIDs.contains(subID) {
                Self.securityLogger.warning("Relay repeatedly closed a subscription; rebuilding connection: \(self.url.absoluteString, privacy: .public)")
                Task { await handleConnectionFailure(generation: generation) }
            } else {
                closedRetriedSubIDs.insert(subID)
                sendREQ(subscriptionID: subID, filters: entry.filters)
            }
        case "NOTICE":
            break
        default:
            break
        }
    }

    private func parseEvent(_ obj: [String: Any]) -> NostrEvent? {
        guard let id = obj["id"] as? String,
              let pubkey = obj["pubkey"] as? String,
              let createdAt = obj["created_at"] as? Int64,
              let kind = obj["kind"] as? Int,
              let tags = obj["tags"] as? [[String]],
              let content = obj["content"] as? String,
              let sig = obj["sig"] as? String
        else { return nil }

        let event = NostrEvent(
            id: id,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: sig
        )

        if !event.verifyEventID() {
            Self.securityLogger.warning("Relay invalid event ID: \(self.url.absoluteString, privacy: .public)")
            return nil
        }

        return event
    }
}
