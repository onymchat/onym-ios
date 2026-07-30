import Foundation
import os.log

/// TEMPORARY transport diagnostics for the device live-delivery bug.
/// Emits nothing in release builds. Remove once resolved.
/// Uses print() rather than os Logger because the scheme runs with
/// OS_ACTIVITY_MODE=disable, which suppresses os_log in Xcode's console.
enum TransportLog {
    #if DEBUG
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    #endif
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("🔌 \(timestamp.string(from: Date())) \(message())")
        #endif
    }
}

/// Persistent WebSocket connection to a single Nostr relay. Owns the
/// REQ/EVENT/EOSE/OK/CLOSE framing and is the only place in the
/// transport layer that touches `URLSessionWebSocketTask`. Reconnect with
/// exponential backoff, heartbeat ping, and a per-publish OK await are
/// all internal — the surface for callers is `connect`, `disconnect`,
/// `publish`, `publishAndAwaitOK`, `subscribe`, `unsubscribe`.
actor NostrRelayConnection {
    let url: URL
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var subscriptions: [String: ([[String: Any]], (NostrEvent) -> Void)] = [:]
    private(set) var isConnected = false
    private var reconnectAttempts = 0
    private var pendingOKContinuations: [String: CheckedContinuation<Bool, any Error>] = [:]
    private var pingTask: Task<Void, Never>?
    private var onOKCallback: ((String, Bool) -> Void)?
    /// Sticky connection intent. Set by `connect()`/`disconnect()` and
    /// checked by a receive loop waking from its backoff sleep, so an
    /// explicitly dropped connection can never resurrect itself.
    private var desiredConnected = false
    /// Instant of the last frame the receive loop delivered. The
    /// heartbeat compares this against its probe time to detect sockets
    /// that died without erroring (NAT drop, suspended-app wake).
    private var lastFrameAt = ContinuousClock.now

    func setOnOK(_ callback: @escaping (String, Bool) -> Void) {
        onOKCallback = callback
    }

    private static let maxReconnectDelay: TimeInterval = 120
    private static let baseReconnectDelay: TimeInterval = 1
    private static let pingInterval: TimeInterval = 30
    private static let connectionTimeout: TimeInterval = 15
    private static let publishTimeout: TimeInterval = 5

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = Self.connectionTimeout
        // WebSocket connections are long-lived — never let the system kill them
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)
    }

    func connect() {
        desiredConnected = true
        guard webSocketTask == nil else {
            TransportLog.log("connect \(url.absoluteString): skipped, socket already exists")
            return
        }
        TransportLog.log("connect \(url.absoluteString): opening socket, will replay \(subscriptions.count) subs")
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        isConnected = true
        Task { await receiveLoop(task: task) }
        startHeartbeat()

        for (subID, (filters, _)) in subscriptions {
            sendREQ(subscriptionID: subID, filters: filters)
        }

        // URLSessionWebSocketTask exposes no reliable onOpen callback. Replay
        // subscriptions shortly after connect so filters added during the
        // handshake window are not lost if the initial send happens too early.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            await self.replaySubscriptions()
        }
    }

    func disconnect() {
        TransportLog.log("disconnect \(url.absoluteString)")
        desiredConnected = false
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        reconnectAttempts = 0
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
        TransportLog.log("publish \(eventID.prefix(8)) → \(url.absoluteString): awaiting OK")

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
            TransportLog.log("publish \(eventID.prefix(8)) → \(url.absoluteString): no OK in 5s, assuming accepted")
            continuation.resume(returning: true)
        }
    }

    private func failPendingOK(eventID: String, error: any Error) {
        if let continuation = pendingOKContinuations.removeValue(forKey: eventID) {
            TransportLog.log("publish \(eventID.prefix(8)) → \(url.absoluteString): send failed: \(error)")
            continuation.resume(throwing: error)
        }
    }

    func subscribe(
        subscriptionID: String,
        filter: [String: Any]
    ) -> AsyncStream<NostrEvent> {
        subscribe(subscriptionID: subscriptionID, filters: [filter])
    }

    /// A single REQ carries every filter (NIP-01 allows it), so one
    /// subscription slot is consumed on the relay no matter how many
    /// filter shapes a caller needs — relays cap concurrent REQs per
    /// connection (strfry defaults to 20) and reject the overflow.
    /// The relay also dedups matches within one REQ, so overlapping
    /// filters no longer deliver the same event several times.
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
        TransportLog.log("CLOSE \(subscriptionID) → \(url.absoluteString)")
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
        let frame: [Any] = ["REQ", subscriptionID] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let string = String(data: data, encoding: .utf8)
        else { return }
        Task {
            guard let task = webSocketTask else {
                TransportLog.log("REQ \(subscriptionID) → \(url.absoluteString): DROPPED, no socket")
                return
            }
            do {
                try await task.send(.string(string))
                TransportLog.log("REQ \(subscriptionID) → \(url.absoluteString): sent \(string)")
            } catch {
                TransportLog.log("REQ \(subscriptionID) → \(url.absoluteString): send FAILED: \(error)")
            }
        }
    }

    private func replaySubscriptions() {
        for (subID, (filters, _)) in subscriptions {
            sendREQ(subscriptionID: subID, filters: filters)
        }
    }

    /// Each loop is bound to the socket it was spawned for and exits the
    /// moment `webSocketTask` no longer points at it. Exactly one loop
    /// ever calls `receive()` on a given socket, and a stale loop can
    /// never cancel a successor's socket while a receive is pending —
    /// the same CFNetwork use-after-free family as the `sendPing` crash
    /// documented above `startHeartbeat()`.
    private func receiveLoop(task: URLSessionWebSocketTask) async {
        TransportLog.log("receiveLoop \(url.absoluteString): started")
        defer { TransportLog.log("receiveLoop \(url.absoluteString): exited") }
        while isConnected, webSocketTask === task {
            do {
                let message = try await task.receive()
                lastFrameAt = ContinuousClock.now
                // A delivered frame proves the connection is healthy.
                // Resetting here instead of in connect() keeps the
                // backoff escalating for a relay that dies during the
                // handshake, rather than retrying it every second.
                reconnectAttempts = 0
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                handleMessage(text)
            } catch {
                guard webSocketTask === task else {
                    TransportLog.log("receiveLoop \(url.absoluteString): stale loop erred (\(error)), yielding to successor")
                    return
                }
                pingTask?.cancel()
                pingTask = nil
                isConnected = false
                task.cancel(with: .abnormalClosure, reason: nil)
                webSocketTask = nil
                reconnectAttempts += 1
                let delay = min(
                    Self.maxReconnectDelay,
                    Self.baseReconnectDelay * pow(2.0, Double(min(reconnectAttempts - 1, 6)))
                )
                TransportLog.log("receiveLoop \(url.absoluteString): receive failed (\(error)), attempt \(reconnectAttempts), reconnecting in \(delay)s")
                try? await Task.sleep(for: .seconds(delay))
                // disconnect() may have run during the backoff sleep —
                // a dropped connection must stay dropped.
                guard desiredConnected, webSocketTask == nil else {
                    TransportLog.log("receiveLoop \(url.absoluteString): reconnect abandoned (desired=\(desiredConnected), socketExists=\(webSocketTask != nil))")
                    return
                }
                connect()
                return
            }
        }
    }

    /// Heartbeat probes liveness with a request/response round trip
    /// instead of `URLSessionWebSocketTask.sendPing`. The CFNetwork ping
    /// handler has a known crash where the pong fires on an internal
    /// queue after the task is cancelled and dereferences a freed
    /// `nw_connection`. A fire-and-forget `.send()` isn't enough either:
    /// on a NAT-dropped or suspend-killed socket the send buffers
    /// locally and "succeeds" while nothing can ever arrive, so the
    /// receive loop hangs forever without an error. The probe is a REQ
    /// whose filter can't match anything (impossible event id), which
    /// NIP-01 requires the relay to answer with an immediate EOSE —
    /// silence past the timeout means the socket is dead.
    private func startHeartbeat() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pingInterval))
                guard !Task.isCancelled, let self else { break }
                guard await self.probeLiveness() else {
                    await self.teardownDeadSocket()
                    break
                }
            }
        }
    }

    private static let probeTimeout: TimeInterval = 10
    private static let probeREQ = #"["REQ","__hb",{"ids":["0000000000000000000000000000000000000000000000000000000000000000"],"limit":1}]"#

    /// Send the probe REQ and report whether *any* frame arrived while
    /// waiting — the EOSE it provokes, or ordinary traffic, both prove
    /// the receive path is alive.
    private func probeLiveness() async -> Bool {
        guard let task = webSocketTask, task.state == .running else {
            TransportLog.log("probe \(url.absoluteString): no running socket (state=\(webSocketTask?.state.rawValue ?? -1))")
            return false
        }
        let sentAt = ContinuousClock.now
        try? await task.send(.string(Self.probeREQ))
        try? await Task.sleep(for: .seconds(Self.probeTimeout))
        // Socket was replaced while waiting — the reconnect that did it
        // started a fresh heartbeat, which owns liveness now.
        guard webSocketTask === task else { return true }
        let alive = lastFrameAt > sentAt
        TransportLog.log("probe \(url.absoluteString): \(alive ? "alive" : "DEAD — no frame within \(Self.probeTimeout)s")")
        return alive
    }

    /// Cancelling the socket makes the pending `receive()` throw, so the
    /// receive loop's error path runs the shared backoff + reconnect
    /// (which also replays subscriptions, fetching whatever the dead
    /// socket missed).
    private func teardownDeadSocket() {
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
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
        else {
            TransportLog.log("frame ← \(url.absoluteString): unparseable (\(text.utf8.count) bytes)")
            return
        }

        switch kind {
        case "EVENT":
            guard array.count >= 3,
                  let subID = array[1] as? String,
                  let eventObj = array[2] as? [String: Any]
            else {
                TransportLog.log("EVENT ← \(url.absoluteString): malformed frame")
                return
            }
            let event = parseEvent(eventObj)
            let matched = subscriptions[subID] != nil
            TransportLog.log("EVENT ← \(url.absoluteString): sub=\(subID) id=\((eventObj["id"] as? String)?.prefix(8) ?? "?") parsed=\(event != nil) subKnown=\(matched)")
            if let event,
               let (_, callback) = subscriptions[subID]
            {
                callback(event)
            }
        case "EOSE":
            TransportLog.log("EOSE ← \(url.absoluteString): sub=\(array.count >= 2 ? "\(array[1])" : "?")")
        case "OK":
            if array.count >= 3,
               let eventID = array[1] as? String,
               let accepted = array[2] as? Bool {
                if let continuation = pendingOKContinuations.removeValue(forKey: eventID) {
                    TransportLog.log("OK ← \(url.absoluteString): id=\(eventID.prefix(8)) accepted=\(accepted)")
                    continuation.resume(returning: accepted)
                } else {
                    TransportLog.log("OK ← \(url.absoluteString): id=\(eventID.prefix(8)) accepted=\(accepted), nothing pending")
                }
                onOKCallback?(eventID, accepted)
            }
        case "NOTICE":
            TransportLog.log("NOTICE ← \(url.absoluteString): \(array.count >= 2 ? "\(array[1])" : text)")
        default:
            TransportLog.log("frame ← \(url.absoluteString): unhandled kind=\(kind)")
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
