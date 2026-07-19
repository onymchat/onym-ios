import AVKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI host for `ChatThreadViewController`. The chat screen is
/// UIKit (per the design call on #150) but the surrounding app is
/// SwiftUI, so this wrapper:
///
/// 1. Embeds the controller via `UIViewControllerRepresentable`.
/// 2. Hides the SwiftUI nav bar — the controller paints its own.
/// 3. Pipes the controller's back tap through `Environment(\.dismiss)`
///    so the surrounding `NavigationStack` pops cleanly.
/// 4. Pushes `ChatMembersView` when the controller fires its
///    "info tapped" closure, via `navigationDestination(isPresented:)`.
///
/// The group name is computed reactively from `chatsFlow` and pushed
/// into the controller on every render — `updateUIViewController`
/// keeps the title in sync as the group renames without re-creating
/// the controller.
struct ChatThreadView: View {
    let groupID: String
    @Bindable var chatsFlow: ChatsFlow
    @Bindable var identitiesFlow: IdentitiesFlow
    let messageRepository: MessageRepository
    let sendMessageInteractor: SendMessageInteractor
    let chatReceiptSender: any ChatReceiptSending
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let setGroupAvatar: @MainActor (String, Data?) async -> Void
    /// Fetches + decrypts image attachments for the bubbles + viewer.
    let imageLoader: ChatImageLoader
    /// Fetches + decrypts video blobs for the full-screen player.
    let videoLoader: ChatVideoLoader
    /// Fetches + decrypts voice blobs for inline playback.
    let voiceLoader: ChatVoiceLoader
    /// When non-nil (opened from Search), the thread cold-opens scrolled
    /// to this message and flashes it, instead of opening at the bottom.
    var scrollToMessageID: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showMembers: Bool = false
    /// One combined picker for both photos and videos (the composer now has
    /// a single paperclip attach button).
    @State private var showMediaPicker: Bool = false
    @State private var pickedItems: [PhotosPickerItem] = []
    /// Media staged in the composer's preview strip, awaiting the Send
    /// confirmation. Sent together as one album (or a single message if
    /// only one item survives).
    @State private var pendingMedia: [PendingMediaItem] = []
    /// The image attachment shown in the full-screen viewer, if any.
    @State private var fullScreen: FullScreenAttachment?
    /// The video attachment shown in the full-screen player, if any.
    @State private var fullScreenVideo: FullScreenVideo?
    /// A failed outgoing media message awaiting a Resend / Delete choice.
    @State private var actionsForMessage: ChatMessage?
    /// The album + start index shown in the full-screen gallery, if any.
    @State private var galleryContext: AlbumGalleryContext?
    /// Incoming message IDs we've already emitted a read receipt for,
    /// so re-renders while the thread stays open don't re-send.
    @State private var ackedReadIDs: Set<UUID> = []
    /// Live snapshot of the group's messages, sorted ascending by
    /// `sentAt`. SwiftUI re-renders on every push so the bridge
    /// hands the controller fresh data via `updateUIViewController`.
    @State private var messages: [ChatMessage] = []

    var body: some View {
        ChatThreadControllerBridge(
            memberProfiles: currentMemberProfiles,
            messages: messages,
            onSendTapped: { body, replyToMessageID in
                // Fire-and-forget. `SendMessageInteractor` does the
                // optimistic insert as `.pending` synchronously
                // before the await, so the new row appears in the
                // `MessageRepository.snapshots` stream we're
                // subscribing to above — the table updates without
                // any extra plumbing here. The interactor also
                // owns the status flip to `.sent` / `.failed`, so
                // a thrown error here would only indicate a
                // precondition violation (no identity, unknown
                // group). Those shouldn't happen mid-chat-screen;
                // swallow with `try?`.
                let interactor = sendMessageInteractor
                let groupID = groupID
                Task {
                    try? await interactor.send(
                        groupID: groupID,
                        body: body,
                        replyToMessageID: replyToMessageID
                    )
                }
            },
            onRetryRequested: { messageID in
                // PR 9: retry a failed outgoing message. Same
                // fire-and-forget shape as the send path — the
                // interactor flips status to .pending before the
                // network work begins (so the glyph swaps to the
                // in-flight clock immediately), runs the fan-out,
                // then flips to .sent / .failed on completion.
                let interactor = sendMessageInteractor
                let groupID = groupID
                Task {
                    await interactor.retry(groupID: groupID, messageID: messageID)
                }
            },
            imageLoader: imageLoader,
            scrollToMessageID: scrollToMessageID,
            onImageTapped: { message in
                if let attachment = message.imageAttachment {
                    fullScreen = FullScreenAttachment(attachment: attachment)
                }
            },
            onVideoTapped: { message in
                if let attachment = message.videoAttachment {
                    fullScreenVideo = FullScreenVideo(attachment: attachment)
                }
            },
            onAttachmentActionsRequested: { message in actionsForMessage = message },
            onAlbumItemTapped: { message, index in
                galleryContext = AlbumGalleryContext(items: message.media, startIndex: index)
            },
            onAttachTapped: { handleAttachTapped() },
            onSendVoiceTapped: { url in handleSendVoice(url: url) },
            voiceLoader: voiceLoader,
            pendingMedia: pendingMedia.map { (id: $0.id, thumbnail: $0.thumbnail) },
            onSendMedia: { handleSendPendingMedia() },
            onRemovePendingMedia: { id in pendingMedia.removeAll { $0.id == id } }
        )
        // One combined picker for photos + videos. Each pick is classified
        // in `onChange` by its content type.
        .photosPicker(
            isPresented: $showMediaPicker, selection: $pickedItems,
            maxSelectionCount: 10, matching: .any(of: [.images, .videos])
        )
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    let isVideo = item.supportedContentTypes.contains {
                        $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent)
                    }
                    if isVideo {
                        guard let movie = try? await item.loadTransferable(type: PickedMovie.self)
                        else { continue }
                        let thumb = await Self.videoThumbnail(for: movie.url)
                            ?? UIImage(systemName: "video") ?? UIImage()
                        pendingMedia.append(PendingMediaItem(
                            thumbnail: thumb, source: .video(movie.url)
                        ))
                    } else {
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let thumb = UIImage(data: data) else { continue }
                        pendingMedia.append(PendingMediaItem(
                            thumbnail: thumb, source: .image(data)
                        ))
                    }
                }
                pickedItems = []
            }
        }
        .fullScreenCover(item: $fullScreen) { item in
            FullScreenImageView(attachment: item.attachment, imageLoader: imageLoader) {
                fullScreen = nil
            }
        }
        .fullScreenCover(item: $fullScreenVideo) { item in
            FullScreenVideoView(attachment: item.attachment, videoLoader: videoLoader) {
                fullScreenVideo = nil
            }
        }
        .fullScreenCover(item: $galleryContext) { context in
            FullScreenGalleryView(
                items: context.items,
                startIndex: context.startIndex,
                imageLoader: imageLoader,
                videoLoader: videoLoader
            ) { galleryContext = nil }
        }
        .confirmationDialog(
            "This media didn't send.",
            isPresented: Binding(
                get: { actionsForMessage != nil },
                set: { if !$0 { actionsForMessage = nil } }
            ),
            titleVisibility: .visible,
            presenting: actionsForMessage
        ) { message in
            Button("Resend") {
                let interactor = sendMessageInteractor
                let groupID = groupID
                let id = message.id
                Task { await interactor.retry(groupID: groupID, messageID: id) }
            }
            Button("Delete", role: .destructive) {
                let interactor = sendMessageInteractor
                let groupID = groupID
                let id = message.id
                Task { await interactor.delete(groupID: groupID, messageID: id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        // The chat screen uses the standard SwiftUI navigation bar (its
        // system back button is the only "back" affordance — the UIKit
        // controller no longer paints its own). Title + member count sit
        // in a centered principal item; the info button opens members.
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(currentGroupName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                        .lineLimit(1)
                    if currentMemberCount > 1 {
                        Text("\(currentMemberCount) members")
                            .font(.system(size: 11))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.title")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMembers = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Group info")
                .accessibilityIdentifier("chat.info")
            }
        }
        .navigationDestination(isPresented: $showMembers) {
            ChatMembersView(
                groupID: groupID,
                chatsFlow: chatsFlow,
                identitiesFlow: identitiesFlow,
                makeShareInviteFlow: makeShareInviteFlow,
                setGroupAvatar: setGroupAvatar
            )
        }
        // Per-thread subscription. `task(id:)` cancels + restarts when
        // groupID changes, so navigating into a different chat
        // doesn't leak the previous group's stream. The owner scopes
        // the stream to this identity's copy of the group — the same
        // group id can belong to another local identity, and each keeps
        // its own thread.
        .task(id: groupID) {
            guard let owner = chatsFlow.groups
                .first(where: { $0.id == groupID })?.ownerIdentityID
            else { return }
            for await snapshot in messageRepository.snapshots(groupID: groupID, owner: owner) {
                messages = snapshot
                // Read receipts: the thread is on-screen (this task is
                // tied to its lifetime), so any incoming message here is
                // "read". Gated by the symmetric setting, batched per
                // sender, and de-duped via `ackedReadIDs`.
                await sendReadReceipts(for: snapshot)
                // Clear the chat-list unread badge: mark the group read up
                // to the newest message the user is now looking at. No-op
                // in the repo when it isn't newer than the stored marker.
                if let newest = snapshot.map(\.sentAt).max() {
                    await chatsFlow.markRead(groupID: groupID, upTo: newest)
                }
            }
        }
    }

    /// Emit `.read` receipts for incoming messages the user is now
    /// looking at. No-op when the setting is off. Groups unacked
    /// incoming IDs by sender and ships one receipt per sender to that
    /// sender's inbox key (resolved from the group's member profiles).
    private func sendReadReceipts(for snapshot: [ChatMessage]) async {
        guard ReadReceiptsPreference.isEnabled else { return }
        guard let group = chatsFlow.groups.first(where: { $0.id == groupID }) else { return }
        var bySender: [String: [UUID]] = [:]
        for message in snapshot
        where message.direction == .incoming && !ackedReadIDs.contains(message.id) {
            bySender[message.senderBlsPubkeyHex, default: []].append(message.id)
        }
        guard !bySender.isEmpty else { return }
        for (senderHex, ids) in bySender {
            guard let inbox = group.memberProfiles[senderHex]?.inboxPublicKey else { continue }
            await chatReceiptSender.send(
                kind: .read,
                messageIDs: ids,
                groupID: group.groupIDData,
                to: inbox
            )
            for id in ids { ackedReadIDs.insert(id) }
        }
    }

    /// Attach button tapped: open the combined photo+video picker
    /// (multi-select), which stages picks in the preview strip. Under the
    /// UI-test loopback harness (which can't drive PHPicker), stage a
    /// generated test image so the strip + Send flow can be exercised.
    private func handleAttachTapped() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-loopback") {
            let data = Self.debugTestImageData()
            let thumb = UIImage(data: data) ?? UIImage()
            pendingMedia.append(PendingMediaItem(thumbnail: thumb, source: .image(data)))
            return
        }
        #endif
        showMediaPicker = true
    }

    /// Voice message recorded (mic button released past the minimum hold):
    /// fire-and-forget send. The interactor inserts the optimistic bubble
    /// before the upload.
    private func handleSendVoice(url: URL) {
        let interactor = sendMessageInteractor
        let groupID = groupID
        Task { try? await interactor.sendVoice(groupID: groupID, audioURL: url) }
    }

    /// Send the staged media as one album (or a single message if only
    /// one item), then clear the strip. Fire-and-forget: the interactor
    /// inserts the optimistic bubble before the uploads.
    private func handleSendPendingMedia() {
        let sources = pendingMedia.map(\.source)
        guard !sources.isEmpty else { return }
        pendingMedia = []
        let interactor = sendMessageInteractor
        let groupID = groupID
        Task { try? await interactor.sendAlbum(groupID: groupID, sources: sources) }
    }

    /// Quick poster frame for a picked video, for the preview-strip
    /// thumbnail (no transcode — just the first frame).
    static func videoThumbnail(for url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
    }

    #if DEBUG
    /// A small solid-colour JPEG for the UI test's image-send path.
    static func debugTestImageData() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 240, height: 160), format: format
        ).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
    #endif

    private var currentGroupName: String {
        chatsFlow.groups.first { $0.id == groupID }?.name ?? "Chat"
    }

    /// Drives the title subtitle ("N members"). Reads from the same
    /// `chatsFlow.groups` source as the name so an admin admitting
    /// a new joiner updates the bar live as the announcement lands.
    private var currentMemberCount: Int {
        chatsFlow.groups.first { $0.id == groupID }?.memberProfiles.count ?? 0
    }

    /// Member profiles for the current group, keyed by BLS pubkey hex.
    /// Feeds the chat thread's sender-name resolution. Reads from the
    /// same `chatsFlow.groups` source as the name/count so it stays
    /// live as joiners land or aliases change.
    private var currentMemberProfiles: [String: MemberProfile] {
        chatsFlow.groups.first { $0.id == groupID }?.memberProfiles ?? [:]
    }
}

private struct ChatThreadControllerBridge: UIViewControllerRepresentable {
    let memberProfiles: [String: MemberProfile]
    let messages: [ChatMessage]
    let onSendTapped: (String, UUID?) -> Void
    let onRetryRequested: (UUID) -> Void
    let imageLoader: ChatImageLoader
    let scrollToMessageID: UUID?
    let onImageTapped: (ChatMessage) -> Void
    let onVideoTapped: (ChatMessage) -> Void
    let onAttachmentActionsRequested: (ChatMessage) -> Void
    let onAlbumItemTapped: (ChatMessage, Int) -> Void
    let onAttachTapped: () -> Void
    let onSendVoiceTapped: (URL) -> Void
    let voiceLoader: ChatVoiceLoader
    let pendingMedia: [(id: UUID, thumbnail: UIImage)]
    let onSendMedia: () -> Void
    let onRemovePendingMedia: (UUID) -> Void

    func makeUIViewController(context: Context) -> ChatThreadViewController {
        let vc = ChatThreadViewController()
        // Set the cold-open target BEFORE the first `update(messages:)`
        // so the initial snapshot lands on it. Only set here (not in
        // `updateUIViewController`) so a later SwiftUI re-render doesn't
        // re-arm the jump after the user has scrolled away.
        vc.openAtMessageID = scrollToMessageID
        vc.onSendTapped = onSendTapped
        vc.onRetryRequested = onRetryRequested
        vc.imageLoader = imageLoader
        vc.onImageTapped = onImageTapped
        vc.onVideoTapped = onVideoTapped
        vc.onAttachmentActionsRequested = onAttachmentActionsRequested
        vc.onAlbumItemTapped = onAlbumItemTapped
        vc.onAttachTapped = onAttachTapped
        vc.onSendVoiceTapped = onSendVoiceTapped
        vc.voiceLoader = voiceLoader
        vc.onSendMedia = onSendMedia
        vc.onRemovePendingMedia = onRemovePendingMedia
        vc.loadViewIfNeeded()
        // Profiles before messages — the first sender-display build
        // reads the profiles to resolve names.
        vc.update(memberProfiles: memberProfiles)
        vc.update(messages: messages)
        vc.setPendingMedia(pendingMedia)
        return vc
    }

    func updateUIViewController(_ vc: ChatThreadViewController, context: Context) {
        // Closures are refreshed every render — SwiftUI captures the
        // *current* send-tap + retry dispatchers, so the version the
        // controller invokes always reflects the live binding. (Back and
        // group-info now live in the SwiftUI nav bar, not the controller.)
        vc.onSendTapped = onSendTapped
        vc.onRetryRequested = onRetryRequested
        vc.imageLoader = imageLoader
        vc.onImageTapped = onImageTapped
        vc.onVideoTapped = onVideoTapped
        vc.onAttachmentActionsRequested = onAttachmentActionsRequested
        vc.onAlbumItemTapped = onAlbumItemTapped
        vc.onAttachTapped = onAttachTapped
        vc.onSendVoiceTapped = onSendVoiceTapped
        vc.voiceLoader = voiceLoader
        vc.onSendMedia = onSendMedia
        vc.onRemovePendingMedia = onRemovePendingMedia
        vc.update(memberProfiles: memberProfiles)
        vc.update(messages: messages)
        vc.setPendingMedia(pendingMedia)
    }
}

/// A picked media item staged in the composer's preview strip, awaiting
/// the Send confirmation. Holds a thumbnail (for the strip) + the raw
/// source (for `sendAlbum`).
private struct PendingMediaItem: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let source: ChatMediaSource
}

/// Identifiable wrapper so the full-screen viewer can be driven by
/// `.fullScreenCover(item:)`.
private struct FullScreenAttachment: Identifiable {
    let id = UUID()
    let attachment: ChatImageAttachment
}

/// Identifiable wrapper for the full-screen video player.
private struct FullScreenVideo: Identifiable {
    let id = UUID()
    let attachment: ChatVideoAttachment
}

/// The album + the tapped start index, driving the full-screen gallery.
private struct AlbumGalleryContext: Identifiable {
    let id = UUID()
    let items: [ChatMediaAttachment]
    let startIndex: Int
}

/// Full-screen, horizontally-paged gallery over an album's items. Images
/// render decrypted; videos play in the dismissible player. Starts on the
/// tapped item; a Close button dismisses (paging owns horizontal drags,
/// so the per-viewer swipe-down isn't used here).
private struct FullScreenGalleryView: View {
    let items: [ChatMediaAttachment]
    let startIndex: Int
    let imageLoader: ChatImageLoader
    let videoLoader: ChatVideoLoader
    let onDismiss: () -> Void

    @State private var selection: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Group {
                        switch item {
                        case .image(let image):
                            GalleryImagePage(attachment: image, imageLoader: imageLoader)
                        case .video(let video):
                            DismissibleVideoPlayerPage(attachment: video, videoLoader: videoLoader)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
        .overlay(alignment: .topLeading) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .accessibilityIdentifier("chat.gallery.close")
        }
        .onAppear { selection = startIndex }
    }
}

/// One image page inside the gallery.
private struct GalleryImagePage: View {
    let attachment: ChatImageAttachment
    let imageLoader: ChatImageLoader
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task { image = try? await imageLoader.image(for: attachment) }
    }
}

/// One video page inside the gallery (loads + plays the decrypted clip).
private struct DismissibleVideoPlayerPage: View {
    let attachment: ChatVideoAttachment
    let videoLoader: ChatVideoLoader
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            if let url = try? await videoLoader.fileURL(for: attachment) {
                player = AVPlayer(url: url)
            }
        }
    }
}

/// `Transferable` that receives a picked video as a file URL we own —
/// videos are too large to load as `Data`, so we copy the picker's
/// temporary file to a location the interactor can read + transcode.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty
                    ? "mov" : received.file.pathExtension)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// Full-screen video player: black backdrop, an `AVPlayer` over the
/// decrypted local file. Dismissed by **swipe down** (a pan recognizer
/// that recognizes simultaneously with the player's own controls, so
/// scrubbing + tap-to-toggle still work) — matching the image viewer;
/// there's no explicit close button.
private struct FullScreenVideoView: View {
    let attachment: ChatVideoAttachment
    let videoLoader: ChatVideoLoader
    let onDismiss: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                DismissibleVideoPlayer(
                    player: player,
                    onDismiss: {
                        player.pause()
                        onDismiss()
                    }
                )
                .ignoresSafeArea()
                .accessibilityIdentifier("chat.video.fullscreen")
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            if let url = try? await videoLoader.fileURL(for: attachment) {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
        }
    }
}

/// `AVPlayerViewController` wrapper that adds a swipe-down-to-dismiss pan
/// gesture. The recognizer only claims predominantly-downward drags and
/// runs simultaneously with the player's built-in controls, so the
/// scrubber and tap-to-toggle keep working. A plain SwiftUI `DragGesture`
/// over `VideoPlayer` wouldn't fire — AVKit's controls consume the
/// touches before SwiftUI's ancestor gesture sees them.
private struct DismissibleVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.view.backgroundColor = .clear
        // Queryable from UI tests to detect the open player (there's no
        // close button; dismissal is swipe-down only).
        controller.view.accessibilityIdentifier = "chat.video.fullscreen"
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        controller.view.addGestureRecognizer(pan)
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onDismiss: () -> Void
        weak var controller: AVPlayerViewController?
        /// Downward-drag distance past which releasing dismisses.
        private let dismissThreshold: CGFloat = 120

        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = controller?.view else { return }
            let translation = gesture.translation(in: view)
            switch gesture.state {
            case .changed:
                view.transform = CGAffineTransform(translationX: 0, y: max(0, translation.y))
            case .ended, .cancelled, .failed:
                if translation.y > dismissThreshold {
                    onDismiss()
                } else {
                    UIView.animate(withDuration: 0.25) { view.transform = .identity }
                }
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = controller?.view else { return true }
            // Only claim predominantly-downward drags — horizontal
            // scrubbing + taps stay with the player's own controls.
            let velocity = pan.velocity(in: view)
            return velocity.y > abs(velocity.x)
        }
    }
}

/// Full-screen image viewer: black backdrop, the decrypted image,
/// **swipe down to dismiss**. The image tracks the drag and the backdrop
/// fades with it; releasing past the threshold dismisses, otherwise it
/// springs back.
private struct FullScreenImageView: View {
    let attachment: ChatImageAttachment
    let imageLoader: ChatImageLoader
    let onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var dragOffset: CGSize = .zero

    /// Downward-drag distance past which releasing dismisses.
    private let dismissThreshold: CGFloat = 120

    /// 0…1 backdrop-fade based on how far the image has been dragged.
    private var dragProgress: CGFloat {
        min(1, max(0, dragOffset.height) / 300)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dragProgress * 0.7).ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .offset(dragOffset)
                    .accessibilityIdentifier("chat.image.fullscreen")
            } else {
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Follow the finger; horizontal drift is allowed but
                    // only the downward distance decides dismissal.
                    dragOffset = value.translation
                }
                .onEnded { value in
                    if value.translation.height > dismissThreshold {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .task {
            image = try? await imageLoader.image(for: attachment)
        }
    }
}
