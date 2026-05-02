import Foundation

/// A reachable transport endpoint. The `URL` scheme is interpreted by the
/// concrete transport: `wss://` for Nostr relays, `onion://` for a future
/// Tor hidden-service transport, etc.
struct TransportEndpoint: Hashable, Sendable {
    let url: URL
}

/// Opaque broadcast topic identifier. The transport is free to map this
/// onto its own routing primitive (a Nostr `["t", topic]` tag, a Tor
/// pubsub channel name, …); callers must treat it as a stable string that
/// identifies a many-to-many channel.
struct TransportTopic: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Opaque inbox identifier — a recipient-derived handle that lets a sender
/// reach exactly one receiver without learning their long-term identity.
/// Derivation is the application's job (e.g. `Identity.inboxTag`); the
/// transport only routes by it.
struct TransportInboxID: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One inbound payload as observed by a topic subscriber. The transport
/// has already validated whatever framing it was responsible for (Nostr
/// event-ID integrity, signature, …) — `payload` is the opaque bytes the
/// sender called `publish` with.
struct InboundMessage: Sendable {
    let topic: TransportTopic
    let payload: Data
    /// Wall-clock timestamp the transport reports for this message.
    let receivedAt: Date
    /// Transport-assigned unique identifier (e.g. NIP-01 event id) that
    /// callers can use to dedupe across redundant endpoints.
    let messageID: String
}

/// Inbox variant of `InboundMessage`.
struct InboundInbox: Sendable {
    let inbox: TransportInboxID
    let payload: Data
    let receivedAt: Date
    let messageID: String
}

/// Acknowledgement returned by `publish` / `send`. `acceptedBy` is the
/// number of endpoints that confirmed acceptance — for Nostr that's the
/// count of relays that returned `OK true`. Concrete transports may treat
/// "no response within timeout" as acceptance to avoid blocking.
struct PublishReceipt: Sendable {
    let messageID: String
    let acceptedBy: Int
}

enum TransportError: Error, Sendable {
    case notConnected
    case publishRejected
    case invalidPayload(String)
}

/// Many-to-many topic-addressed transport. A `MessageTransport` carries
/// opaque `Data` payloads between any number of publishers and
/// subscribers that share a topic. Senders are not authenticated by the
/// transport — that's the application layer's responsibility.
protocol MessageTransport: Sendable {
    func connect(to endpoints: [TransportEndpoint]) async
    func disconnect() async

    @discardableResult
    func publish(_ payload: Data, to topic: TransportTopic) async throws -> PublishReceipt

    /// Subscribe to a topic. `since` lets the caller request a catch-up
    /// window; if nil, the transport picks a sensible recent default.
    /// The returned stream terminates when `unsubscribe` is called or
    /// the consumer stops iterating.
    func subscribe(topic: TransportTopic, since: Date?) -> AsyncStream<InboundMessage>

    func unsubscribe(topic: TransportTopic) async
}

/// Recipient-addressed transport. Unlike `MessageTransport`, each payload
/// targets exactly one inbox. A receiver subscribes by their own inbox
/// identifier; senders address them by the same identifier. The transport
/// makes no claim about who the sender is.
protocol InboxTransport: Sendable {
    func connect(to endpoints: [TransportEndpoint]) async
    func disconnect() async

    @discardableResult
    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt

    func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox>

    func unsubscribe(inbox: TransportInboxID) async
}
