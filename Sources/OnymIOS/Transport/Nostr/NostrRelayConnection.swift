import Foundation
import os.log

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
    private var subscriptions: [String: ([String: Any], (NostrEvent) -> Void)] = [:]
    private(set) var isConnected = false
    private var reconnectAttempts = 0
    private var pendingOKContinuations: [String: CheckedContinuation<Bool, any Error>] = [:]
    private var pingTask: Task<Void, Never>?
    private var onOKCallback: ((String, Bool) -> Void)?

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
        guard webSocketTask == nil else { return }
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        isConnected = true
        reconnectAttempts = 0
        Task { await receiveLoop() }
        startHeartbeat()

        for (subID, (filter, _)) in subscriptions {
            sendREQ(subscriptionID: subID, filter: filter)
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

    private func replaySubscriptions() {
        for (subID, (filter, _)) in subscriptions {
            sendREQ(subscriptionID: subID, filter: filter)
        }
    }

    private func receiveLoop() async {
        while isConnected {
            guard let task = webSocketTask else { break }
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                handleMessage(text)
            } catch {
                pingTask?.cancel()
                pingTask = nil
                isConnected = false
                webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
                webSocketTask = nil
                reconnectAttempts += 1
                let delay = min(
                    Self.maxReconnectDelay,
                    Self.baseReconnectDelay * pow(2.0, Double(min(reconnectAttempts - 1, 6)))
                )
                try? await Task.sleep(for: .seconds(delay))
                connect()
                return
            }
        }
    }

    /// Heartbeat sends a no-op `["CLOSE","__hb"]` instead of using
    /// `URLSessionWebSocketTask.sendPing`. The CFNetwork ping handler has
    /// a known crash where the pong fires on an internal queue after the
    /// task is cancelled and dereferences a freed `nw_connection`. A
    /// plain `.send()` doesn't have that path — if the connection is
    /// dead, the send throws and the receive loop reconnects.
    private func startHeartbeat() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pingInterval))
                guard !Task.isCancelled else { break }
                guard let task = await self?.webSocketTask,
                      task.state == .running else { break }
                try? await task.send(.string("[\"CLOSE\",\"__hb\"]"))
            }
        }
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
