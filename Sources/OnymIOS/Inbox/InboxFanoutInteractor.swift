import CryptoKit
import Foundation

/// Fan out an `InboxTransport` subscription across every persisted
/// identity. Spawns one concurrent subscription Task per identity;
/// re-syncs the set whenever identities are added or removed (with a
/// 250ms debounce to coalesce rapid changes).
///
/// Without this, messages addressed to a non-current identity drop on
/// the floor while the user is on a different identity. PR-4 of the
/// multi-identity stack.
///
/// Cancellation: the caller owns the top-level Task; per-identity
/// subscription Tasks are torn down via `unsubscribe` + `Task.cancel()`
/// when an identity disappears or when `run` is cancelled.
struct InboxFanoutInteractor: Sendable {
    let inboxTransport: any InboxTransport
    let identityRepository: IdentityRepository
    let repository: IncomingInvitationsRepository
    /// Coalescing window — multiple identity changes within this many
    /// milliseconds collapse into one re-subscribe.
    let debounceMilliseconds: UInt64

    init(
        inboxTransport: any InboxTransport,
        identityRepository: IdentityRepository,
        repository: IncomingInvitationsRepository,
        debounceMilliseconds: UInt64 = 250
    ) {
        self.inboxTransport = inboxTransport
        self.identityRepository = identityRepository
        self.repository = repository
        self.debounceMilliseconds = debounceMilliseconds
    }

    /// Run until cancelled. Subscribes to every identity's inbox tag
    /// and keeps the set in sync as identities come and go.
    func run() async {
        let subscriptions = ActiveSubscriptions(
            inboxTransport: inboxTransport,
            repository: repository
        )

        // Apply the current identity set immediately on launch (the
        // identitiesStream replays the current value on subscribe but
        // only delivers it once we await the first element).
        let initial = await identityRepository.currentIdentities()
        await subscriptions.apply(
            Set(initial.map(\.id)),
            tagsByID: Self.tagsByID(initial)
        )

        var pending: Set<IdentityID> = Set(initial.map(\.id))
        var pendingTags: [IdentityID: TransportInboxID] = Self.tagsByID(initial)
        var debounceHandle: Task<Void, Never>?

        for await summaries in identityRepository.identitiesStream {
            if Task.isCancelled { break }
            let nextIDs = Set(summaries.map(\.id))
            let nextTags = Self.tagsByID(summaries)
            guard nextIDs != pending || nextTags != pendingTags else { continue }
            pending = nextIDs
            pendingTags = nextTags

            // Debounce: cancel any prior pending sync, schedule a new
            // one. The actor (`subscriptions`) serializes the apply,
            // so concurrent fires can't interleave.
            debounceHandle?.cancel()
            debounceHandle = Task { [pending, pendingTags] in
                try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
                if Task.isCancelled { return }
                await subscriptions.apply(pending, tagsByID: pendingTags)
            }
        }

        // Stream closed — tear down everything.
        debounceHandle?.cancel()
        await subscriptions.applyEmpty()
    }

    private static func tagsByID(_ summaries: [IdentitySummary]) -> [IdentityID: TransportInboxID] {
        var out: [IdentityID: TransportInboxID] = [:]
        for s in summaries {
            out[s.id] = TransportInboxID(rawValue: Self.inboxTag(from: s.inboxPublicKey))
        }
        return out
    }

    /// Mirror of `IdentityRepository.inboxTag(from:)`. Pure function of
    /// the inbox pubkey; safe to recompute here without going back
    /// through the actor.
    private static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Subscription bookkeeping actor

/// Owns the live per-identity subscription Tasks. `apply` reconciles
/// the desired set against the live set: cancels Tasks for identities
/// that disappeared or whose inbox tag changed, spawns Tasks for new
/// ones, no-ops the rest.
private actor ActiveSubscriptions {
    private let inboxTransport: any InboxTransport
    private let repository: IncomingInvitationsRepository
    private var live: [IdentityID: (tag: TransportInboxID, task: Task<Void, Never>)] = [:]

    init(inboxTransport: any InboxTransport, repository: IncomingInvitationsRepository) {
        self.inboxTransport = inboxTransport
        self.repository = repository
    }

    func apply(_ wanted: Set<IdentityID>, tagsByID: [IdentityID: TransportInboxID]) async {
        for (id, current) in live {
            if !wanted.contains(id) || tagsByID[id] != current.tag {
                current.task.cancel()
                await inboxTransport.unsubscribe(inbox: current.tag)
                live.removeValue(forKey: id)
            }
        }
        for id in wanted {
            guard let tag = tagsByID[id], live[id] == nil else { continue }
            let stream = inboxTransport.subscribe(inbox: tag)
            let task = Task { [repository] in
                for await message in stream {
                    if Task.isCancelled { break }
                    await repository.recordIncoming(
                        id: message.messageID,
                        payload: message.payload,
                        receivedAt: message.receivedAt
                    )
                }
            }
            live[id] = (tag, task)
        }
    }

    func applyEmpty() async {
        for (_, current) in live {
            current.task.cancel()
            await inboxTransport.unsubscribe(inbox: current.tag)
        }
        live.removeAll()
    }
}
