import Foundation
import os.log

/// Persistent WebSocket connection to a single Nostr relay. Owns the
/// REQ/EVENT/EOSE/OK/CLOSE framing and is the only place in the
/// transport layer that touches `URLSessionWebSocketTask`. Reconnect with
/// exponential backoff, an active liveness monitor, and a per-publish OK
/// await are all internal — the surface for callers is `connect`,
/// `disconnect`, `publish`, `publishAndAwaitOK`, `subscribe`,
/// `unsubscribe`, plus `probeAndReconnectIfStale` for app-driven refresh
/// (foreground / regained connectivity) that rebuilds only a dead socket.
actor NostrRelayConnection {
    let url: URL
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var subscriptions: [String: ([String: Any], (NostrEvent) -> Void)] = [:]
    private(set) var isConnected = false
    private var reconnectAttempts = 0
    private var pendingOKContinuations: [String: CheckedContinuation<Bool, any Error>] = [:]
    private var livenessTask: Task<Void, Never>?
    private var onOKCallback: ((String, Bool) -> Void)?
    /// Bumped on every `connect()`. The receive loop and liveness
    /// monitor capture the generation they were started under and bail
    /// the moment it changes, so a forced reconnect (or a reconnect from
    /// the error path) can never leave two overlapping loops fighting
    /// over the same connection state.
    private var connectionGeneration: UInt64 = 0
    /// Wall-clock time of the last frame received on the current socket.
    /// The liveness monitor uses this to detect a half-open connection —
    /// one the OS still believes is open but that delivers nothing.
    private var lastActivityAt = Date()

    func setOnOK(_ callback: @escaping (String, Bool) -> Void) {
        onOKCallback = callback
    }

    // Timings — injectable so the (otherwise minute-scale) liveness /
    // backoff paths are exercisable in tests. Defaults are the
    // production values.
    private let maxReconnectDelay: TimeInterval
    private let baseReconnectDelay: TimeInterval
    /// How often the liveness monitor probes the relay and checks for
    /// staleness.
    private let pingInterval: TimeInterval
    /// If no frame arrives within this window the socket is treated as
    /// dead and force-reconnected. Must comfortably exceed
    /// `pingInterval` so a healthy relay's probe reply keeps it alive.
    private let livenessTimeout: TimeInterval
    /// How long `probeAndReconnectIfStale` waits for the probe's reply
    /// before declaring the socket dead. Short — it runs on a user-facing
    /// refresh (foreground / connectivity), so a healthy relay's EOSE
    /// lands well inside it and no needless rebuild (or inbox replay) happens.
    private let probeReplyWindow: TimeInterval
    private static let connectionTimeout: TimeInterval = 15
    private static let publishTimeout: TimeInterval = 5
    /// Subscription id for the liveness probe. A `REQ` under this id with
    /// a filter that matches nothing draws an immediate `EOSE` from any
    /// conformant relay — our stand-in for a WebSocket pong.
    private static let livenessSubID = "__onym_hb"

    init(
        url: URL,
        pingInterval: TimeInterval = 20,
        livenessTimeout: TimeInterval = 55,
        probeReplyWindow: TimeInterval = 3,
        baseReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 120
    ) {
        self.url = url
        self.pingInterval = pingInterval
        self.livenessTimeout = livenessTimeout
        self.probeReplyWindow = probeReplyWindow
        self.baseReconnectDelay = baseReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = Self.connectionTimeout
        // WebSocket connections are long-lived — never let the system kill them
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)
    }

    func connect() {
        guard webSocketTask == nil else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        isConnected = true
        // NB: `reconnectAttempts` is *not* reset here — a connect() is only
        // an attempt, not a confirmed-live connection. It resets on the
        // first frame actually received (see receiveLoop), so the backoff
        // escalates across a run of failed attempts against a dead relay.
        lastActivityAt = Date()
        Task { await receiveLoop(generation: generation) }
        startLivenessMonitor(generation: generation)

        for (subID, (filter, _)) in subscriptions {
            sendREQ(subscriptionID: subID, filter: filter)
        }

        // URLSessionWebSocketTask exposes no reliable onOpen callback. Replay
        // subscriptions shortly after connect so filters added during the
        // handshake window are not lost if the initial send happens too early.
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

    /// App-driven refresh for the "there's fresh reason to believe the
    /// network changed" triggers (foreground, regained connectivity).
    /// Probe-first: send the liveness `REQ` and wait briefly for any
    /// inbound frame. A healthy socket answers well inside the window, so
    /// we leave it — and its subscriptions — untouched, avoiding a
    /// needless full-inbox `REQ` replay (which storms the relayer; see
    /// the note in `OnymIOSApp`). Only a socket that stays silent is
    /// torn down and rebuilt.
    func probeAndReconnectIfStale() async {
        guard let task = webSocketTask, task.state == .running else {
            // No usable socket at all — rebuild unconditionally.
            forceReconnect()
            return
        }
        let before = lastActivityAt
        do {
            try await sendLivenessProbe(task: task)
        } catch {
            // Send failed outright — the socket is already dead.
            forceReconnect()
            return
        }
        try? await Task.sleep(for: .seconds(probeReplyWindow))
        // Any frame (the probe's EOSE, or real traffic) refreshes
        // `lastActivityAt`; if nothing moved it, the socket is dead.
        if lastActivityAt <= before {
            forceReconnect()
        }
    }

    /// Tear down the current socket and rebuild it immediately, re-issuing
    /// every live subscription. Bumping the generation via `connect()`
    /// guarantees the previous receive loop / monitor exit without racing
    /// the new ones. Preserves `reconnectAttempts` so repeated forced
    /// rebuilds against a flapping/dead link still escalate backoff on the
    /// error path rather than hammering at the flap rate.
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

    func subscribe(
        subscriptionID: String,
        filter: [String: Any]
    ) -> AsyncStream<NostrEvent> {
        let stream = AsyncStream<NostrEvent> { continuation in
            subscriptions[subscriptionID] = (filter, { event in
                continuation.yield(event)
            })
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.unsubscribe(subscriptionID: subscriptionID)
                }
            }
        }
        sendREQ(subscriptionID: subscriptionID, filter: filter)
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

    private func sendREQ(subscriptionID: String, filter: [String: Any]) {
        let frame: [Any] = ["REQ", subscriptionID, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let string = String(data: data, encoding: .utf8)
        else { return }
        Task { try? await webSocketTask?.send(.string(string)) }
    }

    private func replaySubscriptions(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        for (subID, (filter, _)) in subscriptions {
            sendREQ(subscriptionID: subID, filter: filter)
        }
    }

    private func receiveLoop(generation: UInt64) async {
        while generation == connectionGeneration {
            guard let task = webSocketTask else { return }
            do {
                let message = try await task.receive()
                lastActivityAt = Date()
                // A frame actually arrived — the connection is confirmed
                // live, so clear the backoff counter (it's only bumped by
                // `handleConnectionFailure` and never reset by connect()).
                reconnectAttempts = 0
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                handleMessage(text)
            } catch {
                await handleConnectionFailure(generation: generation, backoff: true)
                return
            }
        }
    }

    /// Single funnel for "this socket is dead, rebuild it". Guarded by the
    /// connection generation so a stale receive loop or liveness monitor
    /// that fires after a newer connect() is a no-op. `backoff: true`
    /// applies exponential backoff (error path); `false` reconnects
    /// immediately (liveness probe declared it dead).
    private func handleConnectionFailure(generation: UInt64, backoff: Bool) async {
        guard generation == connectionGeneration else { return }
        livenessTask?.cancel()
        livenessTask = nil
        isConnected = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        reconnectAttempts += 1
        if backoff {
            let delay = min(
                maxReconnectDelay,
                baseReconnectDelay * pow(2.0, Double(min(reconnectAttempts - 1, 6)))
            )
            try? await Task.sleep(for: .seconds(delay))
        }
        guard generation == connectionGeneration else { return }
        connect()
    }

    /// Active liveness monitor. Two jobs, once per `pingInterval`:
    ///
    ///  1. **Detect a half-open socket.** If no frame has arrived within
    ///     `livenessTimeout`, the connection is silently dead — the OS
    ///     still thinks it's open, so `receive()` never throws and the
    ///     error-path reconnect never fires. We force a reconnect.
    ///  2. **Keep the socket provably alive.** Send a `REQ` under
    ///     `livenessSubID` whose filter matches nothing. A conformant
    ///     relay answers with an immediate `EOSE`, which lands in
    ///     `handleMessage` and refreshes `lastActivityAt` — a pong in all
    ///     but name. If the `send` itself throws, the socket is dead now,
    ///     so we reconnect without waiting for the staleness window.
    ///
    /// Every reconnect this triggers goes through `handleConnectionFailure`
    /// with `backoff: true`, so a relay that never answers the probe
    /// (non-conformant, rejects `limit: 0`) escalates the retry delay
    /// instead of looping forever at the ping interval.
    ///
    /// We deliberately avoid `URLSessionWebSocketTask.sendPing`: its
    /// CFNetwork handler has a known crash where the pong fires on an
    /// internal queue after the task is cancelled and dereferences a
    /// freed `nw_connection`. A plain `.send()` has no such path.
    private func startLivenessMonitor(generation: UInt64) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pingInterval ?? 20))
                guard !Task.isCancelled, let self else { break }
                let alive = await self.livenessTick(generation: generation)
                if !alive { break }
            }
        }
    }

    /// One liveness cycle. Returns `false` when the monitor should stop:
    /// either it's superseded by a newer generation (a no-op), or it has
    /// routed a dead socket into `handleConnectionFailure` (which spawns a
    /// fresh monitor). Fail-*closed*: a nil / non-running task is treated
    /// as dead and reconnected, never silently abandoned — this is the one
    /// component meant to catch a socket the error path missed.
    private func livenessTick(generation: UInt64) async -> Bool {
        guard generation == connectionGeneration else { return false }

        guard let task = webSocketTask, task.state == .running else {
            await handleConnectionFailure(generation: generation, backoff: true)
            return false
        }

        if Date().timeIntervalSince(lastActivityAt) > livenessTimeout {
            await handleConnectionFailure(generation: generation, backoff: true)
            return false
        }

        do {
            try await sendLivenessProbe(task: task)
            return true
        } catch {
            await handleConnectionFailure(generation: generation, backoff: true)
            return false
        }
    }

    /// Send the match-nothing `REQ` whose `EOSE` reply serves as a pong.
    /// A `#ids` filter for an all-zero id matches nothing, so the relay
    /// replies with EOSE and never streams live events into it. Awaited
    /// (not fire-and-forget) so the monitor sees a send failure — a dead
    /// socket — and can reconnect; the probe-first refresh path calls it
    /// with `try?`.
    private func sendLivenessProbe(task: URLSessionWebSocketTask) async throws {
        let probe = "[\"REQ\",\"\(Self.livenessSubID)\",{\"ids\":[\"\(String(repeating: "0", count: 64))\"],\"limit\":0}]"
        try await task.send(.string(probe))
    }

    /// Reject incoming frames over 1 MB so a malicious relay can't
    /// exhaust memory.
    private static let maxMessageSize = 1_048_576
    private static let securityLogger = Logger(subsystem: "app.onym.ios", category: "Transport")

    private func handleMessage(_ text: String) {
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
               let (_, callback) = subscriptions[subID]
            {
                callback(event)
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
