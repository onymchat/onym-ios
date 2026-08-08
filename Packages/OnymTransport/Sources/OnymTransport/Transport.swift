import Foundation

/// A reachable transport endpoint. The `URL` scheme is interpreted by the
/// concrete transport: `wss://` for Nostr relays, `onion://` for a future
/// Tor hidden-service transport, etc.
public struct TransportEndpoint: Hashable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

/// Opaque broadcast topic identifier. The transport is free to map this
/// onto its own routing primitive (a Nostr `["t", topic]` tag, a Tor
/// pubsub channel name, …); callers must treat it as a stable string that
/// identifies a many-to-many channel.
public struct TransportTopic: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Opaque inbox identifier — a recipient-derived handle that lets a sender
/// reach exactly one receiver without learning their long-term identity.
/// Derivation is the application's job (e.g. `Identity.inboxTag`); the
/// transport only routes by it.
public struct TransportInboxID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One inbound payload as observed by a topic subscriber. The transport
/// has already validated whatever framing it was responsible for (Nostr
/// event-ID integrity, signature, …) — `payload` is the opaque bytes the
/// sender called `publish` with.
public struct InboundMessage: Sendable {
    let topic: TransportTopic
    let payload: Data
    /// Wall-clock timestamp the transport reports for this message.
    let receivedAt: Date
    /// Transport-assigned unique identifier (e.g. NIP-01 event id) that
    /// callers can use to dedupe across redundant endpoints.
    let messageID: String

    public init(topic: TransportTopic, payload: Data, receivedAt: Date, messageID: String) {
        self.topic = topic
        self.payload = payload
        self.receivedAt = receivedAt
        self.messageID = messageID
    }
}

/// Inbox variant of `InboundMessage`.
public struct InboundInbox: Sendable {
    public let inbox: TransportInboxID
    public let payload: Data
    public let receivedAt: Date
    public let messageID: String

    public init(inbox: TransportInboxID, payload: Data, receivedAt: Date, messageID: String) {
        self.inbox = inbox
        self.payload = payload
        self.receivedAt = receivedAt
        self.messageID = messageID
    }
}

/// Acknowledgement returned by `publish` / `send`. `acceptedBy` is the
/// number of endpoints that confirmed acceptance — for Nostr that's the
/// count of relays that returned `OK true`. Concrete transports may treat
/// "no response within timeout" as acceptance to avoid blocking.
public struct PublishReceipt: Sendable {
    let messageID: String
    public let acceptedBy: Int

    public init(messageID: String, acceptedBy: Int) {
        self.messageID = messageID
        self.acceptedBy = acceptedBy
    }
}

public enum TransportError: Error, Sendable {
    case notConnected
    /// At least one endpoint answered and none accepted — an explicit
    /// refusal, as opposed to `unreachable` where no endpoint could be
    /// talked to at all.
    case publishRejected
    /// Every endpoint failed at the network layer before any could
    /// accept or reject. Carries the first failure's `URLError.Code`
    /// when the underlying error was a URL-loading error (TLS, DNS,
    /// offline, timeout, …); nil for anything else.
    case unreachable(URLError.Code?)
    case invalidPayload(String)
}

/// Many-to-many topic-addressed transport. A `MessageTransport` carries
/// opaque `Data` payloads between any number of publishers and
/// subscribers that share a topic. Senders are not authenticated by the
/// transport — that's the application layer's responsibility.
public protocol MessageTransport: Sendable {
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
public protocol InboxTransport: Sendable {
    func connect(to endpoints: [TransportEndpoint]) async
    func disconnect() async

    @discardableResult
    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt

    func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox>

    func unsubscribe(inbox: TransportInboxID) async
}
