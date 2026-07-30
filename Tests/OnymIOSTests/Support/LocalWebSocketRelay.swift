import CryptoKit
import Foundation
import Network

/// Minimal in-process WebSocket server for transport tests. Not a real
/// Nostr relay — just enough NIP-01 to drive `NostrRelayConnection`:
///
///  - accepts connections (keeps the most recent one), counts them
///  - records every `["REQ", subID, filter...]` (excluding the client's
///    internal liveness probe) so tests can assert REQ replay and filter
///    shape
///  - "stores" events per subID and replays them (+ EOSE) on each REQ,
///    like a real relay's backfill-on-subscribe
///  - auto-answers every REQ (including the liveness probe) with EOSE —
///    disable via `autoRespondEOSE = false` to model a silent/half-open
///    peer for liveness tests
///  - can inject `["CLOSED", subID, reason]` and hard-drop the socket
final class LocalWebSocketRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.ws.relay")
    private let lock = NSLock()
    private var current: NWConnection?
    private var acceptedCount = 0
    /// Recorded REQs in arrival order: (subID, filters). Probe excluded.
    private var recordedREQs: [(subID: String, filters: [[String: Any]])] = []
    /// Events "stored" on the relay, keyed by the subID they replay under.
    private var storedBySubID: [String: [String]] = [:]
    /// Backing storage for the response-mode flags; written by test
    /// threads, read on the listener queue — lock-guarded.
    private var _autoRespondEOSE = true
    private var _autoCLOSESubscriptions = false

    /// When false, the relay answers nothing at all (no EOSE, no stored
    /// replay) — a healthy-looking but silent peer.
    var autoRespondEOSE: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _autoRespondEOSE }
        set { lock.lock(); defer { lock.unlock() }; _autoRespondEOSE = newValue }
    }

    /// When true, every non-probe REQ is answered with
    /// `["CLOSED", subID, …]` — a relay that persistently rejects the
    /// subscription (e.g. a maxSubsPerConnection cap).
    var autoCLOSESubscriptions: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _autoCLOSESubscriptions }
        set { lock.lock(); defer { lock.unlock() }; _autoCLOSESubscriptions = newValue }
    }

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.acceptedCount += 1
            self.current = connection
            self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
    }

    // MARK: - Observation

    /// The OS-assigned loopback port (listener start is asynchronous).
    func port() async throws -> UInt16 {
        try await poll(timeout: 2) {
            guard let p = listener.port?.rawValue, p != 0 else { return nil }
            return p
        }
    }

    /// Connections accepted so far. A reconnect shows up as an increment.
    func connectionCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return acceptedCount
    }

    /// Non-probe REQs seen so far.
    func reqCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return recordedREQs.count
    }

    /// Non-probe REQs recorded for one subscription id, in order.
    func reqs(subID: String) -> [[[String: Any]]] {
        lock.lock(); defer { lock.unlock() }
        return recordedREQs.filter { $0.subID == subID }.map(\.filters)
    }

    /// All recorded (non-probe) subscription ids, in arrival order.
    func recordedSubIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedREQs.map(\.subID)
    }

    /// The most recently REQ'd (non-probe) subscription id.
    func lastRecordedSubID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return recordedREQs.last?.subID
    }

    @discardableResult
    func waitForConnections(_ count: Int, timeout: TimeInterval = 3) async throws -> Int {
        try await poll(timeout: timeout) { connectionCount() >= count ? connectionCount() : nil }
    }

    @discardableResult
    func waitForREQs(_ count: Int, timeout: TimeInterval = 3) async throws -> Int {
        try await poll(timeout: timeout) { reqCount() >= count ? reqCount() : nil }
    }

    // MARK: - Driving

    /// Send a raw text frame to the current connection.
    func push(_ text: String) {
        lock.lock(); let conn = current; lock.unlock()
        guard let conn else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    /// "Store" an event on the relay: replayed (before EOSE) on every
    /// subsequent REQ for `subID` — models a message that arrived while
    /// the client was away and must be backfilled on re-subscribe.
    func store(subID: String, eventJSON: String) {
        lock.lock(); storedBySubID[subID, default: []].append(eventJSON); lock.unlock()
    }

    /// Inject a relay-side subscription termination.
    func sendCLOSED(subID: String, reason: String = "error: too many concurrent REQs") {
        push("[\"CLOSED\",\"\(subID)\",\"\(reason)\"]")
    }

    /// Hard-drop the current connection — the client's `receive()` errors
    /// and its reconnect path must rebuild.
    func dropCurrentConnection() {
        lock.lock(); let conn = current; current = nil; lock.unlock()
        conn?.forceCancel()
    }

    func stop() {
        listener.cancel()
        lock.lock(); let conn = current; current = nil; lock.unlock()
        conn?.forceCancel()
    }

    // MARK: - Private

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            // Re-arm FIRST: a non-final or unparseable frame must not
            // silently kill the read loop mid-test.
            self.receive(on: connection)
            guard isComplete, let data else { return }
            self.handleFrame(data, on: connection)
        }
    }

    /// Record + answer a client `REQ`; drain everything else.
    private func handleFrame(_ data: Data, on connection: NWConnection) {
        guard
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            (array[0] as? String) == "REQ",
            let subID = array[1] as? String
        else { return }
        let filters = array.dropFirst(2).compactMap { $0 as? [String: Any] }

        lock.lock()
        if subID != "__onym_hb" {
            recordedREQs.append((subID: subID, filters: filters))
        }
        let stored = storedBySubID[subID] ?? []
        let respond = _autoRespondEOSE
        let reject = _autoCLOSESubscriptions && subID != "__onym_hb"
        lock.unlock()

        if reject {
            push("[\"CLOSED\",\"\(subID)\",\"error: too many concurrent REQs\"]")
            return
        }
        guard respond else { return }
        for eventJSON in stored {
            push("[\"EVENT\",\"\(subID)\",\(eventJSON)]")
        }
        push("[\"EOSE\",\"\(subID)\"]")
    }

    /// Async poll that yields between checks (never blocks a cooperative
    /// pool thread the way `Thread.sleep` would).
    private func poll<T>(timeout: TimeInterval, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RelayError.timeout
    }

    enum RelayError: Error { case timeout }

    // MARK: - Event construction

    /// A full `["EVENT", subID, {...}]` frame whose event id is a valid
    /// NIP-01 hash of its fields (so `parseEvent`'s `verifyEventID()`
    /// accepts it). The signature is throwaway — the client verifies the
    /// id, not the signature, at this layer.
    static func eventFrame(subID: String, kind: Int, content: String, tag: (String, String)) -> String {
        let event = eventObjectJSON(kind: kind, content: content, tag: tag)
        return "[\"EVENT\",\"\(subID)\",\(event)]"
    }

    /// The bare event object (no frame wrapper) for `store(subID:eventJSON:)`.
    /// The pubkey is derived from `content`, so distinct contents make
    /// distinct events with distinct ids — mirroring the app's
    /// ephemeral-pubkey-per-send design.
    static func eventObjectJSON(kind: Int, content: String, tag: (String, String)) -> String {
        let pubkey = String(
            SHA256.hash(data: Data(content.utf8))
                .map { String(format: "%02x", $0) }.joined().prefix(64)
        )
        let createdAt = 1_700_000_000
        let tags = [[tag.0, tag.1]]
        let canonical: [Any] = [0, pubkey, createdAt, kind, tags, content]
        let serialized = try! JSONSerialization.data(withJSONObject: canonical, options: [])
        let id = Data(SHA256.hash(data: serialized)).map { String(format: "%02x", $0) }.joined()
        let event: [String: Any] = [
            "id": id,
            "pubkey": pubkey,
            "created_at": createdAt,
            "kind": kind,
            "tags": tags,
            "content": content,
            "sig": String(repeating: "0", count: 128),
        ]
        let data = try! JSONSerialization.data(withJSONObject: event, options: [])
        return String(data: data, encoding: .utf8)!
    }
}
