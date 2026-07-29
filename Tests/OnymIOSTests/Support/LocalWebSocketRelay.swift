import CryptoKit
import Foundation
import Network

/// Minimal in-process WebSocket server for transport tests. Not a real
/// Nostr relay — it does just enough to drive `NostrRelayConnection`:
/// accept a connection, keep the most recent one, let a test push raw
/// text frames (e.g. `["EVENT",...]` lines) to it, and let a test
/// forcibly drop it to simulate a socket that has silently died.
final class LocalWebSocketRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.ws.relay")
    private let lock = NSLock()
    private var current: NWConnection?
    private var acceptedCount = 0

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

    /// The OS-assigned loopback port. Available once the listener is
    /// ready; poll briefly since `start` completes asynchronously.
    func port() throws -> UInt16 {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let p = listener.port?.rawValue, p != 0 { return p }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw RelayError.noPort
    }

    /// Number of connections accepted so far. A reconnect shows up as an
    /// increment.
    func connectionCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return acceptedCount
    }

    /// Block until `acceptedCount` reaches `count` or the timeout fires.
    func waitForConnections(_ count: Int, timeout: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connectionCount() >= count { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw RelayError.timeout
    }

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

    /// Hard-drop the current connection — the client's `receive()` errors
    /// and its reconnect path (or a forced `reconnect()`) must rebuild.
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
        connection.receiveMessage { [weak self] _, _, isComplete, error in
            guard let self, error == nil, isComplete else { return }
            // Drain and ignore client frames (REQ / CLOSE / liveness
            // probes); we only need the connection to stay open.
            self.receive(on: connection)
        }
    }

    enum RelayError: Error { case noPort, timeout }

    // MARK: - Event construction

    /// Build a `["EVENT", subID, {...}]` frame whose event id is a valid
    /// NIP-01 hash of its fields, so `NostrRelayConnection.parseEvent`'s
    /// `verifyEventID()` accepts it. Signature is a throwaway — the parser
    /// verifies the id, not the signature.
    static func eventFrame(subID: String, kind: Int, content: String, tag: (String, String)) -> String {
        let pubkey = String(repeating: "a", count: 64)
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
        let frame: [Any] = ["EVENT", subID, event]
        let data = try! JSONSerialization.data(withJSONObject: frame, options: [])
        return String(data: data, encoding: .utf8)!
    }
}
