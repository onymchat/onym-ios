import XCTest
@testable import OnymIOS

/// Unit coverage for `ChatMessage.chatListPreview` — the one-line subtitle
/// the Chats list renders per row.
final class ChatListPreviewTests: XCTestCase {

    private func message(
        body: String = "",
        direction: MessageDirection = .incoming,
        image: ChatImageAttachment? = nil,
        video: ChatVideoAttachment? = nil,
        album: [ChatMediaAttachment]? = nil,
        voice: ChatVoiceAttachment? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            groupID: "g",
            ownerIdentityID: IdentityID(UUID()),
            senderBlsPubkeyHex: "ab",
            body: body,
            sentAt: Date(),
            direction: direction,
            status: .received,
            replyToMessageID: nil,
            groupType: .tyranny,
            imageAttachment: image,
            videoAttachment: video,
            albumAttachments: album,
            voiceAttachment: voice
        )
    }

    private func image() -> ChatImageAttachment {
        ChatImageAttachment(
            sha256: "aa", mimeType: "image/jpeg", byteSize: 1,
            width: 1, height: 1, encKey: Data(count: 32), blurhash: "L", server: nil
        )
    }

    private func voice() -> ChatVoiceAttachment {
        ChatVoiceAttachment(
            sha256: "bb", mimeType: "audio/mp4", byteSize: 1,
            durationSeconds: 2, encKey: Data(count: 32), waveform: [], server: nil
        )
    }

    func test_incomingText_isBodyVerbatim() {
        XCTAssertEqual(message(body: "hello", direction: .incoming).chatListPreview, "hello")
    }

    func test_outgoingText_isPrefixedWithYou() {
        XCTAssertEqual(message(body: "hi", direction: .outgoing).chatListPreview, "You: hi")
    }

    func test_image_showsPhotoLabel() {
        XCTAssertEqual(message(direction: .incoming, image: image()).chatListPreview, "Photo")
        XCTAssertEqual(message(direction: .outgoing, image: image()).chatListPreview, "You: Photo")
    }

    func test_voice_showsVoiceLabel() {
        XCTAssertEqual(message(direction: .incoming, voice: voice()).chatListPreview, "Voice message")
    }

    func test_album_showsAlbumLabel() {
        let album: [ChatMediaAttachment] = [.image(image()), .image(image())]
        XCTAssertEqual(message(direction: .incoming, album: album).chatListPreview, "Album")
    }
}
