import Foundation

/// A picked media item awaiting send — the raw source before encoding.
/// Images arrive as data; videos as a file URL (to transcode). Fed to
/// `SendMessageInteractor.sendAlbum`.
enum ChatMediaSource: Sendable {
    case image(Data)
    case video(URL)
}

/// One item in a multi-media (album) chat message — either an image or a
/// video. Albums carry a `[ChatMediaAttachment]` on the wire; a
/// single-media message keeps using the flat `attachment` /
/// `videoAttachment` fields (unchanged), so this is purely additive.
///
/// Encoded with a `kind` discriminator so the same spelling identifies
/// the case across iOS, Android, and any future reader.
enum ChatMediaAttachment: Equatable, Sendable {
    case image(ChatImageAttachment)
    case video(ChatVideoAttachment)

    /// The poster/image used to render this item's thumbnail: the image
    /// itself, or a video's poster frame.
    var thumbnail: ChatImageAttachment {
        switch self {
        case .image(let image): image
        case .video(let video): video.poster
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    var asImage: ChatImageAttachment? {
        if case .image(let image) = self { return image }
        return nil
    }

    var asVideo: ChatVideoAttachment? {
        if case .video(let video) = self { return video }
        return nil
    }

    /// Every blob SHA-256 this item references (for outbox eviction).
    var blobShas: [String] {
        switch self {
        case .image(let image): [image.sha256]
        case .video(let video): [video.poster.sha256, video.sha256]
        }
    }
}

extension ChatMediaAttachment: Codable {
    enum CodingKeys: String, CodingKey {
        case kind
        case image
        case video
    }

    private enum Kind: String, Codable {
        case image
        case video
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .image:
            self = .image(try c.decode(ChatImageAttachment.self, forKey: .image))
        case .video:
            self = .video(try c.decode(ChatVideoAttachment.self, forKey: .video))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let image):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(image, forKey: .image)
        case .video(let video):
            try c.encode(Kind.video, forKey: .kind)
            try c.encode(video, forKey: .video)
        }
    }
}
