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

    @Environment(\.dismiss) private var dismiss
    @State private var showMembers: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var showVideoPicker: Bool = false
    @State private var pickedVideoItem: PhotosPickerItem?
    /// The image attachment shown in the full-screen viewer, if any.
    @State private var fullScreen: FullScreenAttachment?
    /// The video attachment shown in the full-screen player, if any.
    @State private var fullScreenVideo: FullScreenVideo?
    /// Incoming message IDs we've already emitted a read receipt for,
    /// so re-renders while the thread stays open don't re-send.
    @State private var ackedReadIDs: Set<UUID> = []
    /// Live snapshot of the group's messages, sorted ascending by
    /// `sentAt`. SwiftUI re-renders on every push so the bridge
    /// hands the controller fresh data via `updateUIViewController`.
    @State private var messages: [ChatMessage] = []

    var body: some View {
        ChatThreadControllerBridge(
            groupName: currentGroupName,
            memberCount: currentMemberCount,
            memberProfiles: currentMemberProfiles,
            messages: messages,
            onBack: { dismiss() },
            onShowMembers: { showMembers = true },
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
            onAttachTapped: { handleAttachTapped() },
            onAttachVideoTapped: { handleAttachVideoTapped() }
        )
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem, matching: .images)
        .photosPicker(isPresented: $showVideoPicker, selection: $pickedVideoItem, matching: .videos)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            let interactor = sendMessageInteractor
            let groupID = groupID
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    try? await interactor.sendImage(groupID: groupID, imageData: data)
                }
                pickedItem = nil
            }
        }
        .onChange(of: pickedVideoItem) { _, item in
            guard let item else { return }
            let interactor = sendMessageInteractor
            let groupID = groupID
            Task {
                // Videos are large — load a file URL (not Data) and hand
                // the interactor the URL to transcode.
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    try? await interactor.sendVideo(groupID: groupID, videoURL: movie.url)
                    try? FileManager.default.removeItem(at: movie.url)
                }
                pickedVideoItem = nil
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
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
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

    /// Attach button tapped: open the system photo picker. Under the
    /// UI-test loopback harness (which can't drive PHPicker), send a
    /// generated test image directly instead.
    private func handleAttachTapped() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-loopback") {
            let interactor = sendMessageInteractor
            let groupID = groupID
            let data = Self.debugTestImageData()
            Task { try? await interactor.sendImage(groupID: groupID, imageData: data) }
            return
        }
        #endif
        showPhotoPicker = true
    }

    /// Attach-video button tapped: open the system video picker. Under
    /// the UI-test loopback harness (which can't drive PHPicker *or*
    /// AVFoundation transcoding), send a canned video directly — the
    /// interactor's injected test encoder ignores the URL.
    private func handleAttachVideoTapped() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-loopback") {
            let interactor = sendMessageInteractor
            let groupID = groupID
            let dummyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("uitest-video").appendingPathExtension("mov")
            Task { try? await interactor.sendVideo(groupID: groupID, videoURL: dummyURL) }
            return
        }
        #endif
        showVideoPicker = true
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
    let groupName: String
    let memberCount: Int
    let memberProfiles: [String: MemberProfile]
    let messages: [ChatMessage]
    let onBack: () -> Void
    let onShowMembers: () -> Void
    let onSendTapped: (String, UUID?) -> Void
    let onRetryRequested: (UUID) -> Void
    let imageLoader: ChatImageLoader
    let onImageTapped: (ChatMessage) -> Void
    let onVideoTapped: (ChatMessage) -> Void
    let onAttachTapped: () -> Void
    let onAttachVideoTapped: () -> Void

    func makeUIViewController(context: Context) -> ChatThreadViewController {
        let vc = ChatThreadViewController()
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.onSendTapped = onSendTapped
        vc.onRetryRequested = onRetryRequested
        vc.imageLoader = imageLoader
        vc.onImageTapped = onImageTapped
        vc.onVideoTapped = onVideoTapped
        vc.onAttachTapped = onAttachTapped
        vc.onAttachVideoTapped = onAttachVideoTapped
        vc.loadViewIfNeeded()
        vc.update(groupName: groupName, memberCount: memberCount)
        // Profiles before messages — the first sender-display build
        // reads the profiles to resolve names.
        vc.update(memberProfiles: memberProfiles)
        vc.update(messages: messages)
        return vc
    }

    func updateUIViewController(_ vc: ChatThreadViewController, context: Context) {
        // Closures are refreshed every render — SwiftUI captures the
        // *current* `dismiss` + `showMembers` setters + send-tap
        // dispatcher + retry dispatcher, so the version the
        // controller invokes always reflects the live binding.
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.onSendTapped = onSendTapped
        vc.onRetryRequested = onRetryRequested
        vc.imageLoader = imageLoader
        vc.onImageTapped = onImageTapped
        vc.onVideoTapped = onVideoTapped
        vc.onAttachTapped = onAttachTapped
        vc.onAttachVideoTapped = onAttachVideoTapped
        vc.update(groupName: groupName, memberCount: memberCount)
        vc.update(memberProfiles: memberProfiles)
        vc.update(messages: messages)
    }
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
/// decrypted local file, a Done button to dismiss.
private struct FullScreenVideoView: View {
    let attachment: ChatVideoAttachment
    let videoLoader: ChatVideoLoader
    let onDismiss: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("chat.video.fullscreen")
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                player?.pause()
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
            .accessibilityIdentifier("chat.video.close")
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

/// Full-screen image viewer: black backdrop, the decrypted image, tap
/// anywhere to dismiss.
private struct FullScreenImageView: View {
    let attachment: ChatImageAttachment
    let imageLoader: ChatImageLoader
    let onDismiss: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityIdentifier("chat.image.fullscreen")
            } else {
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .task {
            image = try? await imageLoader.image(for: attachment)
        }
    }
}
