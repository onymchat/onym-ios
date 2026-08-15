import Foundation
import CryptoKit
import OSLog
import OnymTransport
import OnymIdentity
import OnymTransportBlossom
import OnymGroup

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
public actor SendMessageInteractor {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport
    private let messageRepository: MessageRepository
    private let groupRepository: GroupRepository
    private let blossomClient: any BlossomClient
    /// Resolves the base URL stamped into `ChatImageAttachment.server`
    /// so receivers fetch from the same server the sender uploaded to.
    /// A provider (not a frozen string) so it can re-read the current
    /// Blossom configuration — a server change in Settings applies to
    /// the next send, not the next launch. Sampled once per send so
    /// all of one message's attachments agree.
    private let resolveBlossomServerURL: @Sendable () async -> String
    /// Transcodes + extracts a poster from a picked video. Injected so
    /// the UI-test harness can supply a canned encoding instead of
    /// running AVFoundation on a real clip. Defaults to the real encoder.
    private let videoEncoder: @Sendable (URL) async -> ChatVideoEncoder.Encoded?
    /// Reads a recorded `.m4a` into wire form (bytes + duration + waveform).
    /// Injected so the UI-test harness can supply a canned encoding instead
    /// of reading a real file. Defaults to the real encoder.
    private let voiceEncoder: @Sendable (URL) async -> ChatVoiceEncoder.Encoded?
    /// Persists sealed blobs so a failed media send can be resent (even
    /// after an app restart) by re-uploading the exact ciphertext.
    private let outbox: ChatOutbox?
    /// Primed with the plaintext of an outgoing image/poster so the
    /// sender sees the media immediately — the optimistic bubble is now
    /// inserted *before* the upload, so the blob isn't on Blossom yet.
    private let imageLoader: ChatImageLoader?

    private static let logger = Logger(
        subsystem: "app.onym.ios", category: "moderation"
    )

    /// Hard ceiling on an encrypted blob we'll attempt to upload. Sits
    /// under Blossom's ~100MB cap so a long clip fails fast client-side
    /// rather than with an opaque server rejection mid-upload.
    public static let maxUploadBytes = 95 * 1024 * 1024

    public enum SendError: Error, Equatable {
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
        /// The recorded voice clip couldn't be read / encoded.
        case voiceEncodeFailed
    }

    public init(
        identity: IdentityRepository,
        inboxTransport: any InboxTransport,
        messageRepository: MessageRepository,
        groupRepository: GroupRepository,
        blossomClient: any BlossomClient = URLSessionBlossomClient(
            baseURL: URLSessionBlossomClient.defaultBaseURL,
            signerProvider: OnymNostrSignerProvider()
        ),
        blossomServerURL: @escaping @Sendable () async -> String = {
            URLSessionBlossomClient.defaultBaseURL.absoluteString
        },
        videoEncoder: @escaping @Sendable (URL) async -> ChatVideoEncoder.Encoded? = ChatVideoEncoder.encode(fromVideoURL:),
        voiceEncoder: @escaping @Sendable (URL) async -> ChatVoiceEncoder.Encoded? = ChatVoiceEncoder.encode(fromAudioURL:),
        outbox: ChatOutbox? = nil,
        imageLoader: ChatImageLoader? = nil
    ) {
        self.identity = identity
        self.inboxTransport = inboxTransport
        self.messageRepository = messageRepository
        self.groupRepository = groupRepository
        self.blossomClient = blossomClient
        self.resolveBlossomServerURL = blossomServerURL
        self.outbox = outbox
        self.imageLoader = imageLoader
        self.videoEncoder = videoEncoder
        self.voiceEncoder = voiceEncoder
    }

    /// Returns the locally-persisted `ChatMessage` after the fan-out
    /// completes. The returned row always reflects the final status
    /// (`.sent` or `.failed`) — callers that want the optimistic
    /// `.pending` view subscribe to `MessageRepository.snapshots`.
    @discardableResult
    public func send(
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
        // The proof signs the canonical preimage — body bound to this
        // exact (messageID, groupID, sentAtMillis) — so a disclosed
        // (content, signature) pair can't be replayed against another
        // message. Best-effort by design: a signing failure ships the
        // message without a proof (recipients just can't report it)
        // rather than adding a crypto dependency to every text send.
        let moderationAuthenticityProof = await moderationProof(
            messageID: messageID,
            groupID: groupID,
            groupSecret: group.groupSecret,
            sentAtMillis: sentAtMillis,
            body: body
        )
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: replyToMessageID,
            variant: variant,
            moderationAuthenticityProof: moderationAuthenticityProof
        )

        // Optimistic insert — chat UI sees the bubble immediately.
        // Status flips later after the fan-out completes; the bubble
        // never disappears (re-tries flip pending → sent again, not
        // back to a different id).
        //
        // Persist `sentAt` from the wire millis (not the raw `now`):
        // the proof signs the truncated millisecond value, so the
        // stored date must reconstruct exactly that value — the same
        // derivation every recipient makes — or the sender's own row
        // could never re-derive the preimage it signed.
        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: body,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMillis) / 1000.0),
            direction: .outgoing,
            status: .pending,
            replyToMessageID: replyToMessageID,
            groupType: group.groupType,
            moderationAuthenticityProof: moderationAuthenticityProof
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
            failureReason: failureReason,
            moderationAuthenticityProof: pending.moderationAuthenticityProof
        )
    }

    /// Sign the moderation proof preimage for one send.
    ///
    /// Best-effort by design, matching the text path this was factored
    /// out of: a signing failure ships the message without a proof —
    /// recipients just can't report it — rather than making every send
    /// depend on the keychain succeeding.
    ///
    /// Passing a non-empty `media` produces a v2 preimage committing to
    /// those exact bytes. Every media send supplies it, including video,
    /// album, and voice, whose evidence the Authority does not accept
    /// yet: the commitment is only creatable at send time, so omitting
    /// it now would make today's sends permanently unauthenticable and
    /// force a third preimage version later.
    private func moderationProof(
        messageID: UUID,
        groupID: String,
        groupSecret: Data,
        sentAtMillis: Int64,
        body: String,
        media: [ChatModerationProof.MediaCommitment] = []
    ) async -> String? {
        do {
            return try await identity.signWithStellarKey(
                Data(ChatModerationProof.signedContent(
                    messageID: messageID,
                    groupID: groupID,
                    groupSecret: groupSecret,
                    sentAtMillis: sentAtMillis,
                    body: body,
                    media: media
                ).utf8)
            ).base64EncodedString()
        } catch {
            // A systematic failure (e.g. keychain) must be visible in
            // diagnostics. Error only — no message/group identifiers,
            // per the no-activity-logging policy.
            Self.logger.error("moderation proof signing failed: \(error, privacy: .private)")
            return nil
        }
    }

    /// Send an image message. Encodes + AES-GCM-encrypts the image, then
    /// inserts the optimistic bubble **before** the upload so the sender
    /// sees the image immediately (rendered from the primed plaintext)
    /// with a loading indicator. The sealed ciphertext is persisted in
    /// the outbox first, so an upload/fan-out failure leaves a `.failed`
    /// bubble the user can resend (re-uploading the identical bytes) or
    /// delete. Only precondition problems (no identity, unknown group,
    /// un-decodable image) throw; network failures surface as a `.failed`
    /// message status, not a thrown error.
    @discardableResult
    public func sendImage(
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

        guard let encoded = ChatImageEncoder.encode(fromImageData: imageData) else {
            throw SendError.imageEncodeFailed
        }
        let sealed: ChatImageCrypto.Sealed
        do {
            sealed = try ChatImageCrypto.seal(encoded.jpeg)
        } catch {
            throw SendError.imageUploadFailed("encrypt: \(error)")
        }

        let blossomServerURL = await resolveBlossomServerURL()
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

        // Persist the ciphertext for resend + prime the display so the
        // sender's bubble renders the image now, before the blob exists
        // on Blossom.
        await outbox?.store(sha: sealed.sha256Hex, blob: sealed.blob)
        await imageLoader?.prime(sha256: sealed.sha256Hex, plaintext: encoded.jpeg)

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        let moderationAuthenticityProof = await moderationProof(
            messageID: messageID,
            groupID: groupID,
            groupSecret: group.groupSecret,
            sentAtMillis: sentAtMillis,
            body: caption,
            media: [ChatModerationProof.MediaCommitment(
                blobSha256: sealed.sha256Hex,
                mimeType: "image/jpeg",
                plaintextSha256: ChatImageCrypto.sha256Hex(encoded.jpeg),
                plaintextByteLength: encoded.jpeg.count,
                width: encoded.width,
                height: encoded.height
            )]
        )
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: nil,
            variant: variant,
            attachment: attachment,
            moderationAuthenticityProof: moderationAuthenticityProof
        )
        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: caption,
            // From the wire millis, not the raw `now`: the proof signs
            // the truncated value, so the stored date must reconstruct
            // exactly what every recipient derives.
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMillis) / 1000.0),
            direction: .outgoing,
            status: .pending,
            replyToMessageID: nil,
            groupType: group.groupType,
            moderationAuthenticityProof: moderationAuthenticityProof,
            imageAttachment: attachment
        )
        // Optimistic insert BEFORE the upload — the bubble appears
        // immediately with a loading indicator.
        await messageRepository.insert(pending)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }
        let finalStatus = await uploadAndFanOut(
            blobs: [(sealed.blob, "image/jpeg")],
            payload: payload,
            recipients: recipients,
            messageID: messageID,
            groupID: groupID,
            owner: group.ownerIdentityID,
            sentBlobShas: [sealed.sha256Hex]
        )
        return pending.withStatus(finalStatus)
    }

    /// Send a video message. Transcodes to 720p + extracts a poster,
    /// then encrypts + uploads *two* blobs — the poster (small) and the
    /// video (large) — before shipping a `ChatMessagePayload` carrying a
    /// `ChatVideoAttachment` (+ optional caption). Both uploads complete
    /// before the optimistic bubble is inserted, so a receiver never
    /// gets a descriptor pointing at a missing blob. Any encode / size /
    /// upload failure throws before anything is persisted or fanned out.
    @discardableResult
    public func sendVideo(
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

        // Transcode → extract poster. (This is the one heavy step; the
        // bubble appears right after it, then shows a loading indicator
        // through the upload + fan-out.)
        guard let encoded = await videoEncoder(videoURL) else {
            throw SendError.videoEncodeFailed
        }

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

        let blossomServerURL = await resolveBlossomServerURL()
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

        // Persist both ciphertexts for resend; prime the poster so the
        // sender's bubble renders it now (the video blob isn't displayed
        // in the bubble — only the poster is).
        await outbox?.store(sha: posterSealed.sha256Hex, blob: posterSealed.blob)
        await outbox?.store(sha: videoSealed.sha256Hex, blob: videoSealed.blob)
        await imageLoader?.prime(sha256: posterSealed.sha256Hex, plaintext: encoded.poster.jpeg)

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        // Poster first, then the video — the same order they upload in,
        // and the order is inside the signed bytes.
        let moderationAuthenticityProof = await moderationProof(
            messageID: messageID,
            groupID: groupID,
            groupSecret: group.groupSecret,
            sentAtMillis: sentAtMillis,
            body: caption,
            media: [
                ChatModerationProof.MediaCommitment(
                    blobSha256: posterSealed.sha256Hex,
                    mimeType: "image/jpeg",
                    plaintextSha256: ChatImageCrypto.sha256Hex(encoded.poster.jpeg),
                    plaintextByteLength: encoded.poster.jpeg.count,
                    width: encoded.poster.width,
                    height: encoded.poster.height
                ),
                ChatModerationProof.MediaCommitment(
                    blobSha256: videoSealed.sha256Hex,
                    mimeType: "video/mp4",
                    plaintextSha256: ChatImageCrypto.sha256Hex(encoded.mp4),
                    plaintextByteLength: encoded.mp4.count,
                    width: encoded.width,
                    height: encoded.height
                ),
            ]
        )
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: nil,
            variant: variant,
            videoAttachment: videoAttachment,
            moderationAuthenticityProof: moderationAuthenticityProof
        )
        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: caption,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMillis) / 1000.0),
            direction: .outgoing,
            status: .pending,
            replyToMessageID: nil,
            groupType: group.groupType,
            moderationAuthenticityProof: moderationAuthenticityProof,
            videoAttachment: videoAttachment
        )
        // Optimistic insert BEFORE upload.
        await messageRepository.insert(pending)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }
        // Poster first (small, so the recipient's bubble renders quickly),
        // then the video.
        let finalStatus = await uploadAndFanOut(
            blobs: [
                (posterSealed.blob, "image/jpeg"),
                (videoSealed.blob, "video/mp4"),
            ],
            payload: payload,
            recipients: recipients,
            messageID: messageID,
            groupID: groupID,
            owner: group.ownerIdentityID,
            sentBlobShas: [posterSealed.sha256Hex, videoSealed.sha256Hex]
        )
        return pending.withStatus(finalStatus)
    }

    /// Send a multi-media **album** — several picked images/videos as one
    /// message (one caption, one status, one read receipt), rendered as a
    /// grid. Each item is encoded + sealed and its ciphertext persisted
    /// to the outbox; the single optimistic bubble is inserted before the
    /// uploads (all posters/images primed so the grid renders at once),
    /// then every blob uploads and the payload fans out. An upload/
    /// fan-out failure marks the whole album `.failed` (resendable).
    ///
    /// Items that can't be encoded are skipped; if none survive, throws
    /// `imageEncodeFailed`. A single surviving item collapses to a normal
    /// single-media message.
    @discardableResult
    public func sendAlbum(
        groupID: String,
        sources: [ChatMediaSource],
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

        // Encode + seal each item; collect the descriptors + the blobs to
        // upload. Un-encodable items are skipped.
        var items: [ChatMediaAttachment] = []
        var uploads: [(Data, String)] = []
        var shas: [String] = []
        // Accumulated in lockstep with `uploads`/`shas`, so the signed
        // media order is the album's own order. A skipped item is absent
        // from both, which keeps the commitment describing exactly what
        // was sent rather than what was picked.
        var commitments: [ChatModerationProof.MediaCommitment] = []
        let blossomServerURL = await resolveBlossomServerURL()
        for source in sources {
            switch source {
            case .image(let data):
                guard let encoded = ChatImageEncoder.encode(fromImageData: data),
                      let sealed = try? ChatImageCrypto.seal(encoded.jpeg) else { continue }
                let attachment = ChatImageAttachment(
                    sha256: sealed.sha256Hex, mimeType: "image/jpeg",
                    byteSize: sealed.blob.count, width: encoded.width, height: encoded.height,
                    encKey: sealed.key, blurhash: encoded.blurhash, server: blossomServerURL
                )
                await outbox?.store(sha: sealed.sha256Hex, blob: sealed.blob)
                await imageLoader?.prime(sha256: sealed.sha256Hex, plaintext: encoded.jpeg)
                items.append(.image(attachment))
                uploads.append((sealed.blob, "image/jpeg"))
                shas.append(sealed.sha256Hex)
                commitments.append(ChatModerationProof.MediaCommitment(
                    blobSha256: sealed.sha256Hex,
                    mimeType: "image/jpeg",
                    plaintextSha256: ChatImageCrypto.sha256Hex(encoded.jpeg),
                    plaintextByteLength: encoded.jpeg.count,
                    width: encoded.width,
                    height: encoded.height
                ))
            case .video(let url):
                guard let encoded = await videoEncoder(url),
                      let posterSealed = try? ChatImageCrypto.seal(encoded.poster.jpeg),
                      let videoSealed = try? ChatImageCrypto.seal(encoded.mp4),
                      videoSealed.blob.count <= Self.maxUploadBytes else { continue }
                let poster = ChatImageAttachment(
                    sha256: posterSealed.sha256Hex, mimeType: "image/jpeg",
                    byteSize: posterSealed.blob.count, width: encoded.poster.width,
                    height: encoded.poster.height, encKey: posterSealed.key,
                    blurhash: encoded.poster.blurhash, server: blossomServerURL
                )
                let videoAttachment = ChatVideoAttachment(
                    sha256: videoSealed.sha256Hex, mimeType: "video/mp4",
                    byteSize: videoSealed.blob.count, width: encoded.width, height: encoded.height,
                    durationSeconds: encoded.durationSeconds, encKey: videoSealed.key,
                    poster: poster, server: blossomServerURL
                )
                await outbox?.store(sha: posterSealed.sha256Hex, blob: posterSealed.blob)
                await outbox?.store(sha: videoSealed.sha256Hex, blob: videoSealed.blob)
                await imageLoader?.prime(sha256: posterSealed.sha256Hex, plaintext: encoded.poster.jpeg)
                items.append(.video(videoAttachment))
                uploads.append((posterSealed.blob, "image/jpeg"))
                uploads.append((videoSealed.blob, "video/mp4"))
                shas.append(posterSealed.sha256Hex)
                shas.append(videoSealed.sha256Hex)
                commitments.append(ChatModerationProof.MediaCommitment(
                    blobSha256: posterSealed.sha256Hex,
                    mimeType: "image/jpeg",
                    plaintextSha256: ChatImageCrypto.sha256Hex(encoded.poster.jpeg),
                    plaintextByteLength: encoded.poster.jpeg.count,
                    width: encoded.poster.width,
                    height: encoded.poster.height
                ))
                commitments.append(ChatModerationProof.MediaCommitment(
                    blobSha256: videoSealed.sha256Hex,
                    mimeType: "video/mp4",
                    plaintextSha256: ChatImageCrypto.sha256Hex(encoded.mp4),
                    plaintextByteLength: encoded.mp4.count,
                    width: encoded.width,
                    height: encoded.height
                ))
            }
        }
        guard !items.isEmpty else { throw SendError.imageEncodeFailed }

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        // A single surviving item collapses to a normal single-media
        // message (so the album model only kicks in for 2+ items).
        let singleImage: ChatImageAttachment? = items.count == 1 ? items[0].asImage : nil
        let singleVideo: ChatVideoAttachment? = items.count == 1 ? items[0].asVideo : nil
        let album: [ChatMediaAttachment]? = items.count > 1 ? items : nil
        let moderationAuthenticityProof = await moderationProof(
            messageID: messageID,
            groupID: groupID,
            groupSecret: group.groupSecret,
            sentAtMillis: sentAtMillis,
            body: caption,
            media: commitments
        )
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: nil,
            variant: variant,
            attachment: singleImage,
            videoAttachment: singleVideo,
            attachments: album,
            moderationAuthenticityProof: moderationAuthenticityProof
        )
        let pending = ChatMessage(
            id: messageID, groupID: groupID, ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex, body: caption,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMillis) / 1000.0),
            direction: .outgoing, status: .pending, replyToMessageID: nil,
            groupType: group.groupType,
            moderationAuthenticityProof: moderationAuthenticityProof,
            imageAttachment: singleImage, videoAttachment: singleVideo,
            albumAttachments: album
        )
        await messageRepository.insert(pending)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }
        let finalStatus = await uploadAndFanOut(
            blobs: uploads, payload: payload, recipients: recipients,
            messageID: messageID, groupID: groupID, owner: group.ownerIdentityID,
            sentBlobShas: shas
        )
        return pending.withStatus(finalStatus)
    }

    /// Send a voice message. Encrypts the recorded `.m4a` and inserts the
    /// optimistic bubble **before** the upload (mirroring `sendImage`), so
    /// the sender sees the voice bubble immediately (waveform + duration
    /// render from the descriptor) with a loading indicator. The sealed
    /// ciphertext is persisted in the outbox first, so an upload/fan-out
    /// failure leaves a `.failed` bubble the user can resend (re-uploading
    /// the identical bytes) or delete. Only precondition problems (no
    /// identity, unknown group, unreadable clip) throw; network failures
    /// surface as a `.failed` status.
    @discardableResult
    public func sendVoice(
        groupID: String,
        audioURL: URL,
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
            // A voice message never carries a caption.
            variant = .tyranny(body: "")
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            throw SendError.unknownGroup
        }

        guard let encoded = await voiceEncoder(audioURL) else {
            throw SendError.voiceEncodeFailed
        }
        let sealed: ChatImageCrypto.Sealed
        do {
            sealed = try ChatImageCrypto.seal(encoded.m4a)
        } catch {
            throw SendError.voiceEncodeFailed
        }
        guard sealed.blob.count <= Self.maxUploadBytes else {
            throw SendError.videoTooLarge
        }

        let blossomServerURL = await resolveBlossomServerURL()
        let voiceAttachment = ChatVoiceAttachment(
            sha256: sealed.sha256Hex,
            mimeType: "audio/mp4",
            byteSize: sealed.blob.count,
            durationSeconds: encoded.durationSeconds,
            encKey: sealed.key,
            waveform: encoded.waveform,
            server: blossomServerURL
        )

        // Persist the ciphertext for resend. No image prime — the bubble
        // renders from the waveform descriptor, not a thumbnail.
        await outbox?.store(sha: sealed.sha256Hex, blob: sealed.blob)

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        // No width/height: those keys are absent from the preimage for
        // audio rather than carrying a placeholder value.
        let moderationAuthenticityProof = await moderationProof(
            messageID: messageID,
            groupID: groupID,
            groupSecret: group.groupSecret,
            sentAtMillis: sentAtMillis,
            body: "",
            media: [ChatModerationProof.MediaCommitment(
                blobSha256: sealed.sha256Hex,
                mimeType: "audio/mp4",
                plaintextSha256: ChatImageCrypto.sha256Hex(encoded.m4a),
                plaintextByteLength: encoded.m4a.count
            )]
        )
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            replyToMessageID: nil,
            variant: variant,
            voiceAttachment: voiceAttachment,
            moderationAuthenticityProof: moderationAuthenticityProof
        )
        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: "",
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMillis) / 1000.0),
            direction: .outgoing,
            status: .pending,
            replyToMessageID: nil,
            groupType: group.groupType,
            moderationAuthenticityProof: moderationAuthenticityProof,
            voiceAttachment: voiceAttachment
        )
        // Optimistic insert BEFORE the upload.
        await messageRepository.insert(pending)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }
        let finalStatus = await uploadAndFanOut(
            blobs: [(sealed.blob, "audio/mp4")],
            payload: payload,
            recipients: recipients,
            messageID: messageID,
            groupID: groupID,
            owner: group.ownerIdentityID,
            sentBlobShas: [sealed.sha256Hex]
        )
        return pending.withStatus(finalStatus)
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
    public func retry(groupID: String, messageID: UUID) async {
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

        // Preserve the attachment across the resend — the earlier
        // implementation dropped it, resending an image/video as a
        // text-only bubble. The payload carries the same descriptor, and
        // the blob(s) are re-uploaded from the outbox below.
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: Int64(message.sentAt.timeIntervalSince1970 * 1000),
            replyToMessageID: message.replyToMessageID,
            variant: variant,
            attachment: message.imageAttachment,
            videoAttachment: message.videoAttachment,
            attachments: message.albumAttachments,
            voiceAttachment: message.voiceAttachment,
            moderationAuthenticityProof: message.moderationAuthenticityProof
        )

        // Re-upload the persisted ciphertext for any attachment so the
        // recipient's descriptor resolves. Same bytes → same SHA-256, so
        // this is idempotent when the earlier failure was fan-out-only.
        let blobs = await attachmentBlobs(for: message)

        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }

        _ = await uploadAndFanOut(
            blobs: blobs.map { ($0.blob, $0.mimeType) },
            payload: payload,
            recipients: recipients,
            messageID: messageID,
            groupID: groupID,
            owner: group.ownerIdentityID,
            sentBlobShas: blobs.map(\.sha)
        )
    }

    /// Delete an outgoing message locally (used from the failed-media
    /// menu) and evict its outbox blob(s). No network side effects — a
    /// message that never sent has nothing to recall.
    public func delete(groupID: String, messageID: UUID) async {
        guard let activeID = await identity.currentSelectedID() else { return }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.id == groupID && $0.ownerIdentityID == activeID
        }) else { return }
        let messages = await messageRepository.currentMessages(
            groupID: groupID, owner: group.ownerIdentityID
        )
        if let message = messages.first(where: { $0.id == messageID }) {
            for sha in attachmentShas(of: message) { await outbox?.remove(sha: sha) }
        }
        await messageRepository.delete(
            id: messageID, groupID: groupID, owner: group.ownerIdentityID
        )
    }

    /// The persisted outbox blobs backing a message's media, in upload
    /// order (poster before video within a clip). Covers single-media and
    /// albums via `ChatMessage.media`. Empty for text or when the outbox
    /// no longer has the bytes.
    private func attachmentBlobs(
        for message: ChatMessage
    ) async -> [(sha: String, blob: Data, mimeType: String)] {
        var out: [(sha: String, blob: Data, mimeType: String)] = []
        for item in message.media {
            switch item {
            case .image(let image):
                if let blob = await outbox?.load(sha: image.sha256) {
                    out.append((image.sha256, blob, image.mimeType))
                }
            case .video(let video):
                if let posterBlob = await outbox?.load(sha: video.poster.sha256) {
                    out.append((video.poster.sha256, posterBlob, video.poster.mimeType))
                }
                if let videoBlob = await outbox?.load(sha: video.sha256) {
                    out.append((video.sha256, videoBlob, video.mimeType))
                }
            }
        }
        // Voice lives outside `media` (it's not an image/video grid item),
        // so re-upload its blob explicitly.
        if let voice = message.voiceAttachment,
           let blob = await outbox?.load(sha: voice.sha256) {
            out.append((voice.sha256, blob, voice.mimeType))
        }
        return out
    }

    /// All blob SHA-256s referenced by a message's media (for outbox
    /// eviction on delete). Covers single-media, albums, and voice.
    private func attachmentShas(of message: ChatMessage) -> [String] {
        var shas = message.media.flatMap { $0.blobShas }
        if let voice = message.voiceAttachment { shas.append(voice.sha256) }
        return shas
    }

    /// Upload each attachment blob then fan the payload out, updating the
    /// message's status as it goes. Shared by `sendImage` / `sendVideo` /
    /// `retry`. An upload failure marks the message `.failed` and keeps
    /// the outbox blob(s) for a later resend (no fan-out — recipients
    /// never get a descriptor pointing at a missing blob). On a confirmed
    /// `.sent` the outbox blob(s) in `sentBlobShas` are evicted.
    private func uploadAndFanOut(
        blobs: [(Data, String)],
        payload: ChatMessagePayload,
        recipients: [Data],
        messageID: UUID,
        groupID: String,
        owner: IdentityID,
        sentBlobShas: [String]
    ) async -> MessageStatus {
        for (blob, mimeType) in blobs {
            do {
                _ = try await blossomClient.upload(blob, mimeType: mimeType)
            } catch {
                await messageRepository.updateStatus(
                    id: messageID, status: .failed, groupID: groupID,
                    owner: owner, failureReason: .unknown
                )
                return .failed
            }
        }
        let (finalStatus, failureReason) = await fanOut(payload: payload, recipients: recipients)
        await messageRepository.updateStatus(
            id: messageID, status: finalStatus, groupID: groupID,
            owner: owner, failureReason: failureReason
        )
        if finalStatus == .sent {
            for sha in sentBlobShas { await outbox?.remove(sha: sha) }
        }
        return finalStatus
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

private extension ChatMessage {
    /// Copy with a new delivery `status` (attachments + fields preserved).
    /// Used by the send/resend paths to return the message reflecting the
    /// final outcome; the persisted row already carries the same status +
    /// its failure reason.
    func withStatus(_ status: MessageStatus) -> ChatMessage {
        ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            senderBlsPubkeyHex: senderBlsPubkeyHex,
            body: body,
            sentAt: sentAt,
            direction: direction,
            status: status,
            replyToMessageID: replyToMessageID,
            groupType: groupType,
            failureReason: status == .failed ? failureReason : nil,
            moderationAuthenticityProof: moderationAuthenticityProof,
            imageAttachment: imageAttachment,
            videoAttachment: videoAttachment,
            albumAttachments: albumAttachments,
            voiceAttachment: voiceAttachment
        )
    }
}
