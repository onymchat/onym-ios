import Foundation
import CryptoKit

/// Outgoing-message pipeline: persist a `.pending` row locally,
/// seal + ship one envelope per other group member, then flip the
/// status to `.sent` (at least one relay accepted) or `.failed`
/// (every send threw or no relay accepted).
///
/// Mirrors `CreateGroupInteractor.sendInvitations` shape — same
/// `sealInvitation` + `InboxTransport.send` per recipient, same
/// inbox-tag derivation. The local insert happens *before* the fan-
/// out so the chat thread sees the bubble immediately; the status
/// flip is the UI's signal that the network is done.
actor SendMessageInteractor {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport
    private let messageRepository: MessageRepository
    private let groupRepository: GroupRepository
    private let blossomClient: any BlossomClient
    /// Base URL stamped into `ChatImageAttachment.server` so receivers
    /// fetch from the same server the sender uploaded to.
    private let blossomServerURL: String
    /// Transcodes + extracts a poster from a picked video. Injected so
    /// the UI-test harness can supply a canned encoding instead of
    /// running AVFoundation on a real clip. Defaults to the real encoder.
    private let videoEncoder: @Sendable (URL) async -> ChatVideoEncoder.Encoded?

    /// Hard ceiling on an encrypted blob we'll attempt to upload. Sits
    /// under Blossom's ~100MB cap so a long clip fails fast client-side
    /// rather than with an opaque server rejection mid-upload.
    static let maxUploadBytes = 95 * 1024 * 1024

    enum SendError: Error, Equatable {
        case noIdentityLoaded
        case unknownGroup
        /// Current identity isn't in the group's `memberProfiles`. The
        /// roster lookup is by BLS pubkey hex, so this fires when the
        /// creator's own profile was never recorded (shouldn't happen
        /// post-PR-3) or when the active identity switched mid-flight.
        case senderNotAMember
        /// Caller-side guard. Empty bodies are technically valid on
        /// the wire (the payload encodes them) but the interactor
        /// refuses to ship them — a no-op send would burn a relay
        /// publish for nothing.
        case emptyBody
        /// The picked image couldn't be decoded / re-encoded.
        case imageEncodeFailed
        /// Encrypting or uploading the image blob to Blossom failed.
        case imageUploadFailed(String)
        /// The picked video couldn't be transcoded / poster-extracted.
        case videoEncodeFailed
        /// Encrypting or uploading a video (or its poster) blob failed.
        case videoUploadFailed(String)
        /// The transcoded + encrypted video exceeds the upload cap.
        case videoTooLarge
    }

    init(
        identity: IdentityRepository,
        inboxTransport: any InboxTransport,
        messageRepository: MessageRepository,
        groupRepository: GroupRepository,
        blossomClient: any BlossomClient = URLSessionBlossomClient(
            baseURL: URLSessionBlossomClient.defaultBaseURL,
            signerProvider: OnymNostrSignerProvider()
        ),
        blossomServerURL: String = URLSessionBlossomClient.defaultBaseURL.absoluteString,
        videoEncoder: @escaping @Sendable (URL) async -> ChatVideoEncoder.Encoded? = ChatVideoEncoder.encode(fromVideoURL:)
    ) {
        self.identity = identity
        self.inboxTransport = inboxTransport
        self.messageRepository = messageRepository
        self.groupRepository = groupRepository
        self.blossomClient = blossomClient
        self.blossomServerURL = blossomServerURL
        self.videoEncoder = videoEncoder
    }

    /// Returns the locally-persisted `ChatMessage` after the fan-out
    /// completes. The returned row always reflects the final status
    /// (`.sent` or `.failed`) — callers that want the optimistic
    /// `.pending` view subscribe to `MessageRepository.snapshots`.
    @discardableResult
    func send(
        groupID: String,
        body: String,
        replyToMessageID: UUID? = nil,
        now: Date = Date()
    ) async throws -> ChatMessage {
        guard !body.isEmpty else { throw SendError.emptyBody }

        guard let active = await identity.currentIdentity(),
              let activeID = await identity.currentSelectedID() else {
            throw SendError.noIdentityLoaded
        }
        let groups = await groupRepository.currentGroups()
        // Scope to the active identity's copy: the same on-chain group
        // id can belong to two local identities, and the message must
        // be stamped with (and rendered under) the sender's identity.
        guard let group = groups.first(where: {
            $0.id == groupID && $0.ownerIdentityID == activeID
        }) else {
            throw SendError.unknownGroup
        }

        let myBlsHex = active.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
        guard group.memberProfiles[myBlsHex] != nil else {
            throw SendError.senderNotAMember
        }

        // Variant is governance-keyed; today only Tyranny ships.
        // Other group types throw at the payload layer because their
        // variants aren't implemented yet — PR 4 only supports the
        // tyranny case end-to-end.
        let variant: ChatMessageVariant
        switch group.groupType {
        case .tyranny:
            variant = .tyranny(body: body)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            throw SendError.unknownGroup  // surfaces as "not supported"
        }

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: replyToMessageID,
            variant: variant
        )

        // Optimistic insert — chat UI sees the bubble immediately.
        // Status flips later after the fan-out completes; the bubble
        // never disappears (re-tries flip pending → sent again, not
        // back to a different id).
        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: body,
            sentAt: now,
            direction: .outgoing,
            status: .pending,
            replyToMessageID: replyToMessageID,
            groupType: group.groupType
        )
        await messageRepository.insert(pending)

        // Fan out to every member except self. Best-effort per
        // recipient — one failed send doesn't doom the whole message;
        // we mark `.sent` if at least one relay accepted any envelope.
        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }

        let (finalStatus, failureReason) = await fanOut(
            payload: payload,
            recipients: recipients
        )
        await messageRepository.updateStatus(
            id: messageID,
            status: finalStatus,
            groupID: groupID,
            owner: group.ownerIdentityID,
            failureReason: failureReason
        )

        return ChatMessage(
            id: pending.id,
            groupID: pending.groupID,
            ownerIdentityID: pending.ownerIdentityID,
            senderBlsPubkeyHex: pending.senderBlsPubkeyHex,
            body: pending.body,
            sentAt: pending.sentAt,
            direction: pending.direction,
            status: finalStatus,
            replyToMessageID: pending.replyToMessageID,
            groupType: pending.groupType,
            failureReason: failureReason
        )
    }

    /// Send an image message. Encodes + AES-GCM-encrypts the image,
    /// uploads the ciphertext blob to Blossom, then ships a normal
    /// `ChatMessagePayload` carrying a `ChatImageAttachment` (+ optional
    /// caption). The optimistic bubble is inserted *before* the fan-out
    /// (with the full attachment, since the SHA-256 is known right after
    /// the local encrypt), but *after* a successful upload so receivers
    /// never get an attachment pointing at a missing blob. Upload
    /// failure throws before anything is persisted or fanned out.
    @discardableResult
    func sendImage(
        groupID: String,
        imageData: Data,
        caption: String = "",
        now: Date = Date()
    ) async throws -> ChatMessage {
        guard let active = await identity.currentIdentity(),
              let activeID = await identity.currentSelectedID() else {
            throw SendError.noIdentityLoaded
        }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.id == groupID && $0.ownerIdentityID == activeID
        }) else {
            throw SendError.unknownGroup
        }
        let myBlsHex = active.blsPublicKey.map { String(format: "%02x", $0) }.joined()
        guard group.memberProfiles[myBlsHex] != nil else {
            throw SendError.senderNotAMember
        }
        let variant: ChatMessageVariant
        switch group.groupType {
        case .tyranny:
            variant = .tyranny(body: caption)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            throw SendError.unknownGroup
        }

        // Encode → encrypt → upload. All before the optimistic insert so
        // a failed upload leaves no dangling bubble.
        guard let encoded = ChatImageEncoder.encode(fromImageData: imageData) else {
            throw SendError.imageEncodeFailed
        }
        let sealed: ChatImageCrypto.Sealed
        do {
            sealed = try ChatImageCrypto.seal(encoded.jpeg)
        } catch {
            throw SendError.imageUploadFailed("encrypt: \(error)")
        }
        do {
            _ = try await blossomClient.upload(sealed.blob, mimeType: "image/jpeg")
        } catch {
            throw SendError.imageUploadFailed(String(describing: error))
        }

        let attachment = ChatImageAttachment(
            sha256: sealed.sha256Hex,
            mimeType: "image/jpeg",
            byteSize: sealed.blob.count,
            width: encoded.width,
            height: encoded.height,
            encKey: sealed.key,
            blurhash: encoded.blurhash,
            server: blossomServerURL
        )

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: nil,
            variant: variant,
            attachment: attachment
        )

        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: caption,
            sentAt: now,
            direction: .outgoing,
            status: .pending,
            replyToMessageID: nil,
            groupType: group.groupType,
            imageAttachment: attachment
        )
        await messageRepository.insert(pending)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }
        let (finalStatus, failureReason) = await fanOut(payload: payload, recipients: recipients)
        await messageRepository.updateStatus(
            id: messageID,
            status: finalStatus,
            groupID: groupID,
            owner: group.ownerIdentityID,
            failureReason: failureReason
        )
        return ChatMessage(
            id: pending.id,
            groupID: pending.groupID,
            ownerIdentityID: pending.ownerIdentityID,
            senderBlsPubkeyHex: pending.senderBlsPubkeyHex,
            body: pending.body,
            sentAt: pending.sentAt,
            direction: pending.direction,
            status: finalStatus,
            replyToMessageID: pending.replyToMessageID,
            groupType: pending.groupType,
            failureReason: failureReason,
            imageAttachment: pending.imageAttachment
        )
    }

    /// Send a video message. Transcodes to 720p + extracts a poster,
    /// then encrypts + uploads *two* blobs — the poster (small) and the
    /// video (large) — before shipping a `ChatMessagePayload` carrying a
    /// `ChatVideoAttachment` (+ optional caption). Both uploads complete
    /// before the optimistic bubble is inserted, so a receiver never
    /// gets a descriptor pointing at a missing blob. Any encode / size /
    /// upload failure throws before anything is persisted or fanned out.
    @discardableResult
    func sendVideo(
        groupID: String,
        videoURL: URL,
        caption: String = "",
        now: Date = Date()
    ) async throws -> ChatMessage {
        guard let active = await identity.currentIdentity(),
              let activeID = await identity.currentSelectedID() else {
            throw SendError.noIdentityLoaded
        }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.id == groupID && $0.ownerIdentityID == activeID
        }) else {
            throw SendError.unknownGroup
        }
        let myBlsHex = active.blsPublicKey.map { String(format: "%02x", $0) }.joined()
        guard group.memberProfiles[myBlsHex] != nil else {
            throw SendError.senderNotAMember
        }
        let variant: ChatMessageVariant
        switch group.groupType {
        case .tyranny:
            variant = .tyranny(body: caption)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            throw SendError.unknownGroup
        }

        // Transcode → extract poster. All before any upload / insert so a
        // failure leaves no dangling bubble.
        guard let encoded = await videoEncoder(videoURL) else {
            throw SendError.videoEncodeFailed
        }

        // Poster blob (small) — same shape as a sent image.
        let posterSealed: ChatImageCrypto.Sealed
        let videoSealed: ChatImageCrypto.Sealed
        do {
            posterSealed = try ChatImageCrypto.seal(encoded.poster.jpeg)
            videoSealed = try ChatImageCrypto.seal(encoded.mp4)
        } catch {
            throw SendError.videoUploadFailed("encrypt: \(error)")
        }
        guard videoSealed.blob.count <= Self.maxUploadBytes else {
            throw SendError.videoTooLarge
        }
        do {
            _ = try await blossomClient.upload(posterSealed.blob, mimeType: "image/jpeg")
            _ = try await blossomClient.upload(videoSealed.blob, mimeType: "video/mp4")
        } catch {
            throw SendError.videoUploadFailed(String(describing: error))
        }

        let poster = ChatImageAttachment(
            sha256: posterSealed.sha256Hex,
            mimeType: "image/jpeg",
            byteSize: posterSealed.blob.count,
            width: encoded.poster.width,
            height: encoded.poster.height,
            encKey: posterSealed.key,
            blurhash: encoded.poster.blurhash,
            server: blossomServerURL
        )
        let videoAttachment = ChatVideoAttachment(
            sha256: videoSealed.sha256Hex,
            mimeType: "video/mp4",
            byteSize: videoSealed.blob.count,
            width: encoded.width,
            height: encoded.height,
            durationSeconds: encoded.durationSeconds,
            encKey: videoSealed.key,
            poster: poster,
            server: blossomServerURL
        )

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: nil,
            variant: variant,
            videoAttachment: videoAttachment
        )

        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: caption,
            sentAt: now,
            direction: .outgoing,
            status: .pending,
            replyToMessageID: nil,
            groupType: group.groupType,
            videoAttachment: videoAttachment
        )
        await messageRepository.insert(pending)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }
        let (finalStatus, failureReason) = await fanOut(payload: payload, recipients: recipients)
        await messageRepository.updateStatus(
            id: messageID,
            status: finalStatus,
            groupID: groupID,
            owner: group.ownerIdentityID,
            failureReason: failureReason
        )
        return ChatMessage(
            id: pending.id,
            groupID: pending.groupID,
            ownerIdentityID: pending.ownerIdentityID,
            senderBlsPubkeyHex: pending.senderBlsPubkeyHex,
            body: pending.body,
            sentAt: pending.sentAt,
            direction: pending.direction,
            status: finalStatus,
            replyToMessageID: pending.replyToMessageID,
            groupType: pending.groupType,
            failureReason: failureReason,
            videoAttachment: pending.videoAttachment
        )
    }

    /// Retry a previously-failed outgoing message. Looks up the row
    /// by `messageID`, flips status back to `.pending` so the UI
    /// shows the in-flight glyph, then re-runs the fan-out using the
    /// original payload fields (same UUID + body + sentAt) so
    /// receivers can dedup against any earlier delivery. Status is
    /// flipped to `.sent` / `.failed` on completion.
    ///
    /// No-op (silent) when:
    ///   - The message isn't in the local repository for that group.
    ///   - The row isn't `.outgoing` with `.failed` status. Retrying
    ///     an already-pending or already-sent message would
    ///     double-deliver; retrying an incoming message makes no
    ///     sense.
    ///   - The group isn't on this device, no identity is loaded,
    ///     or the message's group type isn't supported by v1 chat.
    func retry(groupID: String, messageID: UUID) async {
        // Resolve the active identity first so the group + message
        // lookups can be scoped to the right owner (a group id can be
        // shared across two local identities).
        guard let activeID = await identity.currentSelectedID() else { return }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.id == groupID && $0.ownerIdentityID == activeID
        }) else { return }

        let messages = await messageRepository.currentMessages(
            groupID: groupID,
            owner: group.ownerIdentityID
        )
        guard let message = messages.first(where: { $0.id == messageID }),
              message.direction == .outgoing,
              message.status == .failed
        else { return }

        let myBlsHex = message.senderBlsPubkeyHex
        guard group.memberProfiles[myBlsHex] != nil else { return }

        let variant: ChatMessageVariant
        switch group.groupType {
        case .tyranny:
            variant = .tyranny(body: message.body)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            return
        }

        // Flip the row to `.pending` first so the UI's status
        // glyph swaps from the red-bang to the in-flight clock
        // before the network work starts. Receivers dedup against
        // any prior delivery via the same `messageID`.
        await messageRepository.updateStatus(
            id: messageID,
            status: .pending,
            groupID: groupID,
            owner: group.ownerIdentityID
        )

        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: Int64(message.sentAt.timeIntervalSince1970 * 1000),
            replyToMessageID: message.replyToMessageID,
            variant: variant
        )

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }

        let (finalStatus, failureReason) = await fanOut(payload: payload, recipients: recipients)
        await messageRepository.updateStatus(
            id: messageID,
            status: finalStatus,
            groupID: groupID,
            owner: group.ownerIdentityID,
            failureReason: failureReason
        )
    }

    /// Encode the payload, seal one envelope per recipient, ship
    /// each, return `.sent` if any relay accepted (or the recipient
    /// list was empty), `.failed` if every send threw or every
    /// relay rejected. Shared between `send` and `retry` since the
    /// per-recipient fan-out shape is identical.
    ///
    /// On `.failed` the second tuple element carries the categorized
    /// reason (first failure wins — recipients almost always fail the
    /// same way since they share the relay set) so the UI can explain
    /// the red bang. Always nil on `.sent`.
    private func fanOut(
        payload: ChatMessagePayload,
        recipients: [Data]
    ) async -> (MessageStatus, SendFailureReason?) {
        let payloadBytes: Data
        do {
            payloadBytes = try JSONEncoder().encode(payload)
        } catch {
            // JSONEncoder on a static-typed Codable value can't
            // realistically fail; surface as a transport failure
            // so the caller marks the row `.failed`.
            return (.failed, .unknown)
        }

        var successCount = 0
        var failureReason: SendFailureReason?
        for inboxKey in recipients {
            let sealed: Data
            do {
                sealed = try await identity.sealInvitation(
                    payload: payloadBytes,
                    to: inboxKey
                )
            } catch {
                // Best-effort per recipient; remember why the first
                // one failed. Sealing happens before the network, so
                // any error here is a local crypto problem.
                if failureReason == nil { failureReason = .encryptionFailed }
                continue
            }
            do {
                let receipt = try await inboxTransport.send(
                    sealed,
                    to: TransportInboxID(rawValue: Self.inboxTag(from: inboxKey))
                )
                if receipt.acceptedBy >= 1 {
                    successCount += 1
                } else if failureReason == nil {
                    // Transport reported completion with zero
                    // acceptances instead of throwing.
                    failureReason = .relayRejected
                }
            } catch {
                if failureReason == nil { failureReason = Self.categorize(error) }
                continue
            }
        }

        // Empty roster (only the sender is a member) is fine — the
        // message is local-only. Anything with recipients must reach
        // at least one to count as sent.
        if recipients.isEmpty || successCount > 0 {
            return (.sent, nil)
        }
        return (.failed, failureReason ?? .unknown)
    }

    /// Map a transport-layer error onto the user-explainable category
    /// persisted with the failed row. URL-loading codes are grouped
    /// coarsely: "you're offline" (actionable by the user), "TLS
    /// failed" (actionable by the relay operator), and everything
    /// else network-ish as "unreachable".
    static func categorize(_ error: any Error) -> SendFailureReason {
        guard let transportError = error as? TransportError else {
            return .unknown
        }
        switch transportError {
        case .notConnected:
            return .noRelayConnection
        case .publishRejected, .invalidPayload:
            return .relayRejected
        case .unreachable(let code):
            switch code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                return .secureConnectionFailed
            default:
                return .relayUnreachable
            }
        }
    }

    /// Same derivation as `IdentityRepository.inboxTag(from:)` —
    /// duplicated here because the repo's helper is private and we
    /// only need the formula, not the keychain lookup. Matches
    /// `CreateGroupInteractor.inboxTag(from:)`.
    private static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let hash = hasher.finalize()
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
