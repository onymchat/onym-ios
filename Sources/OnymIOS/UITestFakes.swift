#if DEBUG
import Foundation

/// App-side fakes used by `OnymIOSApp` when launched with the
/// `--ui-testing` argument. They live in production sources (not the
/// test target) because `OnymIOSApp.init` constructs them directly,
/// but the entire file is gated by `#if DEBUG` so none of it ships
/// to Release.
///
/// Distinct from the more-elaborate fakes under
/// `Tests/OnymIOSTests/Support/` (which power unit tests via
/// `@testable import OnymIOS` and have scripted/failing modes). Here
/// we just want deterministic fixtures the UI tests can assert
/// against — no scripting, no error injection.

// MARK: - Relayer

/// Returns a fixed pair of known relayers regardless of input. Tests
/// can assert on these names / URLs deterministically.
struct UITestKnownRelayersFetcher: KnownRelayersFetcher {
    static let testnet = RelayerEndpoint(
        name: "UITest Testnet Relayer",
        url: URL(string: "https://uitest-testnet-relayer.example")!,
        networks: ["testnet"]
    )
    static let publicNet = RelayerEndpoint(
        name: "UITest Mainnet Relayer",
        url: URL(string: "https://uitest-mainnet-relayer.example")!,
        networks: ["public"]
    )

    func fetchLatest() async throws -> [RelayerEndpoint] {
        [Self.testnet, Self.publicNet]
    }
}

/// In-memory `RelayerSelectionStore` so each UI test launch starts
/// with no persisted configuration (the auto-populate path then
/// hydrates from the `UITestKnownRelayersFetcher` above).
final class UITestRelayerSelectionStore: RelayerSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: RelayerConfiguration = .empty
    private var cachedList: [RelayerEndpoint] = []

    func loadConfiguration() -> RelayerConfiguration {
        lock.withLock { configuration }
    }

    func saveConfiguration(_ configuration: RelayerConfiguration) {
        lock.withLock { self.configuration = configuration }
    }

    func loadCachedKnownList() -> [RelayerEndpoint] {
        lock.withLock { cachedList }
    }

    func saveCachedKnownList(_ list: [RelayerEndpoint]) {
        lock.withLock { cachedList = list }
    }
}

// MARK: - Contracts

/// Returns a fixed two-release manifest. v0.0.2 is newer (default-to-
/// latest picks it) and includes all five governance types on testnet
/// only. v0.0.1 is older and has a subset. Mainnet stays empty so the
/// "No contracts yet" branch can be exercised.
struct UITestContractsManifestFetcher: ContractsManifestFetcher {
    func fetchLatest() async throws -> ContractsManifest {
        let v002 = ContractRelease(
            release: "v0.0.2",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            contracts: [
                ContractEntry(network: .testnet, type: .anarchy,   id: "CDWYYK"),
                ContractEntry(network: .testnet, type: .democracy, id: "CBEBQM"),
                ContractEntry(network: .testnet, type: .oligarchy, id: "CBHY24"),
                ContractEntry(network: .testnet, type: .oneonone,  id: "CAHXGZ"),
                ContractEntry(network: .testnet, type: .tyranny,   id: "CC6Y2F"),
            ]
        )
        let v001 = ContractRelease(
            release: "v0.0.1",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_001),
            contracts: [
                ContractEntry(network: .testnet, type: .anarchy,   id: "CDSIJT"),
                ContractEntry(network: .testnet, type: .democracy, id: "CBYHYJ"),
            ]
        )
        return ContractsManifest(version: 1, releases: [v002, v001])
    }
}

/// In-memory `AnchorSelectionStore` so each UI test launch starts
/// with no persisted selections.
final class UITestAnchorSelectionStore: AnchorSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var selections: [AnchorSelectionKey: String] = [:]
    private var manifest: ContractsManifest?

    func loadSelections() -> [AnchorSelectionKey: String] {
        lock.withLock { selections }
    }

    func saveSelections(_ selections: [AnchorSelectionKey: String]) {
        lock.withLock { self.selections = selections }
    }

    func loadCachedManifest() -> ContractsManifest? {
        lock.withLock { manifest }
    }

    func saveCachedManifest(_ manifest: ContractsManifest) {
        lock.withLock { self.manifest = manifest }
    }
}

// MARK: - Loopback inbox transport (--ui-loopback)

/// In-process `InboxTransport` for UI tests: routes payloads between
/// local subscribers by inbox tag, with store-and-forward so a send
/// that lands before the recipient subscribes is replayed on subscribe
/// (mirrors a Nostr relay's catch-up window). Lets two identities on
/// one device exchange invitations / messages / receipts with no
/// network. Only wired when the app is launched with `--ui-loopback`.
final class UITestLoopbackInboxTransport: InboxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [String: [InboundInbox]] = [:]
    private var subscribers: [String: [UUID: AsyncStream<InboundInbox>.Continuation]] = [:]
    private var sequence = 0

    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}

    @discardableResult
    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        let tag = inbox.rawValue
        lock.lock()
        sequence += 1
        let message = InboundInbox(
            inbox: inbox,
            payload: payload,
            receivedAt: Date(),
            messageID: "loopback-\(sequence)"
        )
        buffers[tag, default: []].append(message)
        let liveConts = Array((subscribers[tag] ?? [:]).values)
        lock.unlock()

        for continuation in liveConts { continuation.yield(message) }
        return PublishReceipt(messageID: message.messageID, acceptedBy: 1)
    }

    func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        let tag = inbox.rawValue
        return AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[tag, default: [:]][id] = continuation
            // Snapshot the backlog *after* registering so a concurrent
            // send is delivered live rather than dropped — and excluded
            // from the snapshot so it isn't also replayed (no dup).
            let backlog = buffers[tag] ?? []
            lock.unlock()

            for message in backlog { continuation.yield(message) }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[tag]?.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func unsubscribe(inbox: TransportInboxID) async {
        lock.lock()
        subscribers[inbox.rawValue] = nil
        lock.unlock()
    }
}

// MARK: - In-memory chain ledger (--ui-loopback)

/// Shared in-memory stand-in for the SEP contract's on-chain state.
/// One instance is created per app launch and fed to both the write
/// path (`create_group` / `update_commitment`) and the read path
/// (`get_commitment`), so a group anchored by one identity verifies
/// against the exact same `(commitment, epoch)` when another identity
/// materializes it. The Poseidon proof/commitment itself stays real
/// FFI — only the relayer/chain round-trip is faked.
final class UITestChainLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SEPCommitmentEntry] = [:]

    func recordCreate(groupIDHex: String, commitment: Data) {
        lock.withLock {
            entries[groupIDHex] = SEPCommitmentEntry(
                commitment: commitment, epoch: 0, timestamp: nil, tier: nil, active: nil
            )
        }
    }

    /// `update_commitment` advances the epoch by one and swaps in the
    /// new commitment (the approver computes `newEpoch = epoch + 1`
    /// locally, so this must match).
    func recordUpdate(groupIDHex: String, commitmentNew: Data) {
        lock.withLock {
            let oldEpoch = entries[groupIDHex]?.epoch ?? 0
            entries[groupIDHex] = SEPCommitmentEntry(
                commitment: commitmentNew, epoch: oldEpoch + 1,
                timestamp: nil, tier: nil, active: nil
            )
        }
    }

    func commitment(groupIDHex: String) -> SEPCommitmentEntry? {
        lock.withLock { entries[groupIDHex] }
    }
}

/// Fake `SEPContractTransport` backed by a `UITestChainLedger`.
/// Dispatches on the invocation's `function`, round-tripping the
/// generic payload/response through JSON so it stays type-safe without
/// knowing the concrete Codable types.
struct UITestSEPContractTransport: SEPContractTransport {
    let ledger: UITestChainLedger

    private struct CreatePeek: Decodable { let group_id: Data; let commitment: Data }
    private struct UpdatePeek: Decodable { let group_id: Data; let publicInputs: [Data] }
    private struct GroupIDPeek: Decodable { let group_id: Data }

    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let payloadData = try encoder.encode(invocation.payload)

        switch invocation.function {
        case "create_group":
            let peek = try decoder.decode(CreatePeek.self, from: payloadData)
            ledger.recordCreate(groupIDHex: Self.hex(peek.group_id), commitment: peek.commitment)
            return try Self.reencode(
                SEPSubmissionResponse(accepted: true, transactionHash: "uitest-create", message: nil),
                as: Response.self, encoder: encoder, decoder: decoder
            )
        case "update_commitment":
            let peek = try decoder.decode(UpdatePeek.self, from: payloadData)
            // Tyranny update PI is [c_old, epoch_old, c_new, admin_pk, group_id_fr];
            // c_new is index 2.
            let commitmentNew = peek.publicInputs.count > 2 ? peek.publicInputs[2] : Data()
            ledger.recordUpdate(groupIDHex: Self.hex(peek.group_id), commitmentNew: commitmentNew)
            return try Self.reencode(
                SEPSubmissionResponse(accepted: true, transactionHash: "uitest-update", message: nil),
                as: Response.self, encoder: encoder, decoder: decoder
            )
        case "get_commitment":
            let peek = try decoder.decode(GroupIDPeek.self, from: payloadData)
            guard let entry = ledger.commitment(groupIDHex: Self.hex(peek.group_id)) else {
                throw SEPError.invalidResponse(statusCode: 404, body: "group not anchored")
            }
            return try Self.reencode(entry, as: Response.self, encoder: encoder, decoder: decoder)
        default:
            throw SEPError.invalidResponse(statusCode: 400, body: "unsupported \(invocation.function)")
        }
    }

    private static func reencode<T: Encodable, R: Decodable>(
        _ value: T, as: R.Type, encoder: JSONEncoder, decoder: JSONDecoder
    ) throws -> R {
        try decoder.decode(R.self, from: try encoder.encode(value))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - In-memory Blossom (--ui-loopback)

/// In-process `BlossomClient` for UI tests: stores blobs by their
/// SHA-256 so image upload/download round-trips with no network. One
/// instance is shared between the send path and `ChatImageLoader` so a
/// just-uploaded blob is immediately fetchable by the other identity.
final class UITestBlossomClient: BlossomClient, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
        let sha = ChatImageCrypto.sha256Hex(blob)
        lock.withLock { blobs[sha] = blob }
        return BlobDescriptor(sha256: sha, url: "uitest://blossom/\(sha)", size: blob.count)
    }

    func download(sha256: String) async throws -> Data {
        guard let data = (lock.withLock { blobs[sha256] }) else {
            throw BlossomError.badStatus(404)
        }
        return data
    }
}

#endif
