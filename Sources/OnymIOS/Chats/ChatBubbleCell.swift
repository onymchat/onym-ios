import SwiftUI
import UIKit

/// Resolved sender presentation for one bubble — computed by
/// `ChatThreadViewController` (which alone knows the group's member
/// profiles + run grouping) and handed to the cell. The cell stays a
/// dumb renderer: it doesn't look up aliases or hash pubkeys itself.
///
/// `accent` is derived from the sender's BLS pubkey via
/// `OnymAccent.forSender(blsPubkeyHex:)`, so it's a stable per-person
/// color rather than anything tied to the (spoofable) alias.
struct ChatSenderDisplay {
    /// Alias if the member set one, else a short BLS-fingerprint
    /// fallback. Only rendered when `showNameHeader` is true.
    let name: String
    /// Per-sender color. Tints the incoming bubble; fills the outgoing
    /// bubble; colors the name header.
    let accent: OnymAccent
    /// Show the name header above this bubble. The controller sets this
    /// only at the start of a run of consecutive same-sender incoming
    /// messages, and never in 1-on-1 groups (one other person — naming
    /// them on every run is noise).
    let showNameHeader: Bool

    /// Neutral default used by the cell when no sender info is supplied
    /// (and by older call sites). Blue, no header — matches the
    /// pre-sender-differentiation look.
    static let unknown = ChatSenderDisplay(name: "", accent: .blue, showNameHeader: false)
}

/// Resolved quote shown at the top of a bubble that replies to an
/// earlier message — the Telegram-style inset preview. Built by
/// `ChatThreadViewController` by looking the reply target up in the
/// local message list; the cell just renders it.
///
/// The target is resolved *live* (not snapshotted into the payload),
/// so when it isn't on this device the controller hands over
/// `unavailable` and the cell renders a muted placeholder instead of
/// a real sender + snippet.
struct ChatReplyQuote {
    /// Quoted sender's display name (alias or BLS fingerprint).
    let name: String
    /// Quoted message body, rendered on a single truncated line.
    let snippet: String
    /// Quoted sender's accent — colors the leading bar and the name,
    /// so the quote reads as "from that person" at a glance.
    let accent: OnymAccent
    /// The reply target isn't in the local store (never delivered, or
    /// deleted). Renders a muted "message unavailable" placeholder and
    /// the quote isn't tappable.
    let isUnavailable: Bool

    /// Placeholder for a reply whose target this device doesn't have.
    static let unavailable = ChatReplyQuote(
        name: "", snippet: "", accent: .blue, isUnavailable: true
    )
}

/// One message bubble row. Two visual styles toggled by
/// `ChatMessage.direction`:
///
///   - `.outgoing` — filled with the sender's accent, pinned to the
///     trailing edge.
///   - `.incoming` — tinted with the sender's accent, pinned to the
///     leading edge, optionally topped by a colored name header.
///
/// Sender differentiation: there are no avatars, so consecutive
/// incoming messages from one person are grouped under a single
/// accent-colored name header (`ChatSenderDisplay.showNameHeader`), and
/// the bubble itself carries that sender's accent tint. The accent is a
/// hash of the BLS pubkey, not the alias, so it doubles as a cheap
/// visual fingerprint that an alias-spoofer can't forge.
///
/// Status indicator (PR 9): outgoing rows show a tiny glyph below
/// the bubble's trailing edge that reflects `ChatMessage.status`
/// (clock / check / red bang). Incoming rows hide the indicator —
/// the message arriving is the proof. Tapping a `.failed` bubble
/// invokes `onRetryRequested`, which the controller wires to
/// `SendMessageInteractor.retry`.
final class ChatBubbleCell: UITableViewCell {
    /// Separate reuse pools for text vs media/voice bubbles. A media cell
    /// activates the fixed 75%-width constraint; keeping text bubbles in
    /// their own pool means a short text message can never dequeue a cell
    /// that still carries that lock (which rendered it full-width). Same
    /// cell class, two identifiers — the provider picks by message content.
    static let textReuseID = "ChatBubbleCell.text"
    static let mediaReuseID = "ChatBubbleCell.media"
    /// Generic identifier for unit tests that construct a cell directly;
    /// the production table registers the two pool identifiers above.
    static let reuseID = "ChatBubbleCell"

    /// Whether a message renders as a media/voice bubble (picks the
    /// media reuse pool) vs a plain text bubble.
    static func hasMedia(_ message: ChatMessage) -> Bool {
        !message.media.isEmpty || message.voiceAttachment != nil
    }

    /// Max bubble width as a fraction of the cell's content width.
    /// Matches the usual messenger convention — long messages wrap
    /// but never reach the opposite edge.
    private let maxWidthFraction: CGFloat = 0.75

    private let bubble = UIView()
    private let bodyLabel = UILabel()
    /// Image attachment view (shown when `message.imageAttachment != nil`).
    /// Sits above the caption; the blurhash placeholder renders first,
    /// then the decrypted image swaps in from `ChatImageLoader`.
    private let attachmentImageView = UIImageView()
    /// SHA-256 of the attachment currently being loaded — guards the
    /// async image set against cell reuse.
    private var currentImageSha: String?
    /// Fired when the attachment image is tapped (full-screen viewer for
    /// a photo, or the video player for a video).
    private var onImageTapped: (() -> Void)?
    private var imageTapRecognizer: UITapGestureRecognizer?
    /// Play-button glyph shown over the poster when the attachment is a
    /// video. Hidden for photos.
    private let playOverlay = UIImageView()
    /// Duration pill (`m:ss`) shown at the poster's corner for a video.
    private let durationLabel = UILabel()
    /// Spinner shown over an outgoing attachment while it's uploading /
    /// fanning out (`.pending`). Hidden once sent or failed.
    private let attachmentSpinner = UIActivityIndicatorView(style: .medium)
    /// Red "failed" badge shown over an outgoing attachment that didn't
    /// send; tapping the media opens the Resend / Delete menu.
    private let attachmentFailedBadge = UIImageView()
    private let statusImageView = UIImageView()
    /// Second checkmark, sat just left of `statusImageView` and shown
    /// only for `.delivered` / `.read` so the pair reads as a
    /// double-check (SF Symbols has no native double-check glyph).
    private let statusImageView2 = UIImageView()
    /// Why the send failed, rendered under a `.failed` outgoing bubble
    /// next to the red bang so the user isn't left guessing. Text
    /// comes from `SendFailureReason.explanation` (or a generic
    /// fallback) plus the retry call-to-action. Hidden for every
    /// other status and for incoming rows.
    private let failureLabel = UILabel()
    private let nameLabel = UILabel()

    // Reply quote (Telegram-style inset preview at the top of the
    // bubble). `quoteContainer` holds the accent bar + the two labels;
    // it's hidden unless the message replies to another. Tapping it
    // fires `onQuoteTapped` so the host can jump to the original.
    private let quoteContainer = UIView()
    private let quoteBar = UIView()
    private let quoteNameLabel = UILabel()
    private let quoteSnippetLabel = UILabel()

    /// Incoming bubble tint opacity over the background. Low enough that
    /// `OnymTokens.text` stays readable on top, high enough that the
    /// sender's accent reads at a glance.
    private let incomingTintAlpha: Double = 0.20

    /// Set by the diffable data source's cell provider on every
    /// dequeue. Fires when the user taps a `.failed` bubble —
    /// `configure(message:onRetry:)` only installs the tap target
    /// when the message is retry-eligible, so other states never
    /// fire this.
    private var onRetryRequested: (() -> Void)?
    private var retryTapRecognizer: UITapGestureRecognizer?

    /// Set by the cell provider when the message replies to another
    /// and the target is available. Fires when the user taps the
    /// quote — the host scrolls to + flashes the original. Cleared on
    /// every reuse so a recycled cell doesn't keep a stale target.
    private var onQuoteTapped: (() -> Void)?
    private var quoteTapRecognizer: UITapGestureRecognizer?

    /// Fired when the user drags the bubble far enough left to arm a
    /// reply (Telegram-style). Available on every message regardless of
    /// direction or status. Set on each `configure`; reset transform on
    /// reuse so a recycled mid-drag cell starts clean.
    var onSwipeToReply: (() -> Void)?
    private var swipePan: UIPanGestureRecognizer!
    private let replyHint = UIImageView()
    /// Drag distance (points) past which releasing arms a reply.
    private let swipeReplyThreshold: CGFloat = 56
    /// How far the bubble can travel — past the threshold it resists so
    /// the gesture has a clear "armed" ceiling.
    private let swipeMaxTravel: CGFloat = 72
    /// True once the current drag crossed the threshold — drives the
    /// one-shot haptic and the release decision.
    private var swipeArmed = false
    private let swipeHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Direction-dependent constraints — only one pair is active at a
    // time. Each pair contains the alignment pin (`==` to the pinned
    // edge) and the opposite-edge breathing-room gap on the *other*
    // side. Pairing this way prevents the obvious-but-wrong layout:
    // pinning `leading == +12` while also asserting `leading >= +56`
    // breaks every cell with a constraint log.
    private var outgoingConstraints: [NSLayoutConstraint] = []
    private var incomingConstraints: [NSLayoutConstraint] = []

    // Direction-dependent "where does the cell's bottom come from"
    // constraint. For incoming, the bubble's bottom is the cell's
    // bottom (status indicator hidden, no extra height). For
    // outgoing, the status indicator's bottom drives the cell so
    // the indicator has room below the bubble.
    private var bubbleBottomConstraint: NSLayoutConstraint!
    private var statusBottomConstraint: NSLayoutConstraint!
    /// Bottom anchor when the failure explanation is showing — the
    /// label is taller than the status glyph, so it drives the cell's
    /// height instead of `statusBottomConstraint`.
    private var failureBottomConstraint: NSLayoutConstraint!

    // Direction-independent "where does the bubble's top come from"
    // toggle. With a name header, the bubble hangs off the header's
    // bottom; without one (the common case + every outgoing row), the
    // bubble pins to the cell's top. Exactly one is active at a time.
    private var bubbleTopToContentConstraint: NSLayoutConstraint!
    private var bubbleTopToNameConstraint: NSLayoutConstraint!
    private var nameTopConstraint: NSLayoutConstraint!

    // Body-top toggle for the reply quote. Without a quote the body
    // pins to the bubble's top inset (the common case); with one it
    // hangs off the quote container's bottom. Exactly one is active.
    private var bodyTopToBubbleConstraint: NSLayoutConstraint!
    private var bodyTopToQuoteConstraint: NSLayoutConstraint!
    // Image-attachment toggle constraints. Active only when the message
    // carries an image: the image pins to the bubble top and the body
    // (caption) hangs off the image's bottom. The aspect constraint is
    // recreated per `configure` from the attachment's w/h.
    private var imageTopToBubbleConstraint: NSLayoutConstraint!
    private var bodyTopToImageConstraint: NSLayoutConstraint!
    private var attachmentAspectConstraint: NSLayoutConstraint?
    /// Album grid (2+ media items). Shown in place of the single
    /// `attachmentImageView` when the message carries an album.
    private let albumGridView = AlbumGridView()
    private var albumTopToBubbleConstraint: NSLayoutConstraint!
    private var bodyTopToAlbumConstraint: NSLayoutConstraint!
    private var albumAspectConstraint: NSLayoutConstraint?
    /// Fired when an album tile is tapped: (messageID-less) tile index.
    private var onAlbumTapIndex: ((Int) -> Void)?

    /// Inline voice-message player, shown in place of the image/album when
    /// the message carries a `ChatVoiceAttachment`.
    private let voiceView = ChatVoiceMessageView()
    private var voiceTopToBubbleConstraint: NSLayoutConstraint!
    private var bodyTopToVoiceConstraint: NSLayoutConstraint!
    /// Pins the bubble to a fixed (max) width whenever it carries an
    /// attachment, so the image/poster frame is fully determined by the
    /// attachment's known aspect ratio *before* the blob loads. Without
    /// it the bubble hugs the image view's intrinsic size — tiny for the
    /// blurhash placeholder, large once the real image lands — so the
    /// bubble visibly jumps when the download resolves. Inactive for
    /// text-only messages (they keep hugging their content width).
    private var attachmentBubbleWidthConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.backgroundColor = UIColor(OnymTokens.bg)
        buildBubble()
        buildQuote()
        buildStatusIndicator()
        buildNameLabel()
        layoutBubble()
        installSwipeToReply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Reset a recycled cell to the plain-text baseline so it never
    /// inherits the previous message's media layout — most visibly, a
    /// short text bubble stretched to the fixed image/album/voice width
    /// (`attachmentBubbleWidthConstraint`) or an aspect ratio left active
    /// from an image it no longer shows. `configure` re-applies whatever
    /// *this* message needs on top of the clean slate, so the bubble's
    /// size is computed from scratch every dequeue.
    override func prepareForReuse() {
        super.prepareForReuse()
        // Stop any in-flight voice playback so a recycled cell doesn't keep
        // audio going for a scrolled-away message.
        voiceView.reset()

        // Drop the fixed-width + aspect constraints that only a media /
        // voice message installs — otherwise a reused text bubble keeps the
        // 75%-of-width lock and renders full-width.
        attachmentBubbleWidthConstraint.isActive = false
        attachmentAspectConstraint?.isActive = false
        attachmentAspectConstraint = nil
        albumAspectConstraint?.isActive = false
        albumAspectConstraint = nil

        // Detach every media/voice top-pin; `configure` re-activates the
        // one this message needs (and falls back to body-hangs-off-bubble).
        imageTopToBubbleConstraint.isActive = false
        bodyTopToImageConstraint.isActive = false
        albumTopToBubbleConstraint.isActive = false
        bodyTopToAlbumConstraint.isActive = false
        voiceTopToBubbleConstraint.isActive = false
        bodyTopToVoiceConstraint.isActive = false
        bodyTopToQuoteConstraint.isActive = false
        bodyTopToBubbleConstraint.isActive = true

        // Hide + clear all media chrome.
        attachmentImageView.isHidden = true
        attachmentImageView.image = nil
        albumGridView.isHidden = true
        voiceView.isHidden = true
        playOverlay.isHidden = true
        durationLabel.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentFailedBadge.isHidden = true
        currentImageSha = nil
    }

    /// Swap colors + alignment + status indicator for the message.
    /// Caller (the diffable data source's cell provider) invokes
    /// this on every dequeue *and* every reconfigure — status flips
    /// on the same UUID land here too.
    func configure(
        message: ChatMessage,
        sender: ChatSenderDisplay = .unknown,
        reply: ChatReplyQuote? = nil,
        onRetry: (() -> Void)? = nil,
        onQuoteTapped: (() -> Void)? = nil,
        onSwipeToReply: (() -> Void)? = nil,
        imageLoader: ChatImageLoader? = nil,
        voiceLoader: ChatVoiceLoader? = nil,
        onImageTapped: (() -> Void)? = nil,
        onVideoTapped: (() -> Void)? = nil,
        onAlbumItemTapped: ((Int) -> Void)? = nil,
        onVoiceFailedTapped: (() -> Void)? = nil
    ) {
        // Reuse safety: a cell recycled mid-drag must start at rest.
        resetSwipeState()
        self.onSwipeToReply = onSwipeToReply
        bodyLabel.text = message.body
        switch message.direction {
        case .outgoing:
            // Own messages: solid fill in the user's own accent (so
            // "your color" is consistent with the members list and
            // every group). Right-aligned, status glyph below.
            bubble.backgroundColor = UIColor(sender.accent.color)
            bodyLabel.textColor = UIColor(OnymTokens.onAccent)
            NSLayoutConstraint.deactivate(incomingConstraints)
            NSLayoutConstraint.activate(outgoingConstraints)
            bubbleBottomConstraint.isActive = false
            applyStatus(message.status, failureReason: message.failureReason)
        case .incoming:
            // Others' messages: low-opacity tint in the sender's accent
            // — distinguishable per person while keeping body text on
            // the regular text token readable.
            bubble.backgroundColor = UIColor(sender.accent.color.opacity(incomingTintAlpha))
            bodyLabel.textColor = UIColor(OnymTokens.text)
            NSLayoutConstraint.deactivate(outgoingConstraints)
            NSLayoutConstraint.activate(incomingConstraints)
            statusBottomConstraint.isActive = false
            failureBottomConstraint.isActive = false
            bubbleBottomConstraint.isActive = true
            statusImageView.isHidden = true
            statusImageView2.isHidden = true
            failureLabel.isHidden = true
            failureLabel.text = nil
        }
        applyNameHeader(sender)
        applyReplyQuote(reply, direction: message.direction, onTap: onQuoteTapped)
        let media = message.media
        if let voice = message.voiceAttachment {
            applyVoice(
                voice,
                voiceLoader: voiceLoader,
                direction: message.direction,
                status: message.status,
                accent: sender.accent,
                onFailedTap: onVoiceFailedTapped
            )
        } else if media.count > 1 {
            applyAlbum(media, imageLoader: imageLoader, onTapIndex: onAlbumItemTapped)
        } else {
            applyAttachment(
                image: message.imageAttachment,
                video: message.videoAttachment,
                imageLoader: imageLoader,
                onTap: message.videoAttachment != nil ? onVideoTapped : onImageTapped
            )
        }
        applyAttachmentSendState(message)

        // Failed media uses the tap-for-options overlay (Resend / Delete)
        // rather than the verbose text-retry label — hide that label and
        // keep the compact status glyph below the bubble.
        let hasAttachment = !message.media.isEmpty || message.voiceAttachment != nil
        if hasAttachment, message.direction == .outgoing, message.status == .failed {
            failureLabel.isHidden = true
            failureLabel.text = nil
            failureBottomConstraint.isActive = false
            statusBottomConstraint.isActive = true
        }

        // Retry tap is only installed when the message is failed
        // *and* the host provided a retry callback. Cell reuse:
        // first remove any prior recognizer so a previously-failed
        // bubble doesn't keep its tap target after status flips.
        if let existing = retryTapRecognizer {
            bubble.removeGestureRecognizer(existing)
            retryTapRecognizer = nil
        }
        onRetryRequested = nil
        if message.status == .failed, message.direction == .outgoing, let onRetry {
            onRetryRequested = onRetry
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedBubble))
            bubble.addGestureRecognizer(tap)
            retryTapRecognizer = tap
        }
    }

    /// Show or hide the accent-colored sender name above the bubble,
    /// re-pinning the bubble's top to whichever anchor applies. Called
    /// on every `configure` (including cell reuse), so a row that
    /// previously showed a header drops it cleanly when reused for a
    /// mid-run message.
    private func applyNameHeader(_ sender: ChatSenderDisplay) {
        if sender.showNameHeader {
            nameLabel.text = sender.name
            nameLabel.textColor = UIColor(sender.accent.color)
            nameLabel.isHidden = false
            bubbleTopToContentConstraint.isActive = false
            nameTopConstraint.isActive = true
            bubbleTopToNameConstraint.isActive = true
        } else {
            nameLabel.isHidden = true
            nameTopConstraint.isActive = false
            bubbleTopToNameConstraint.isActive = false
            bubbleTopToContentConstraint.isActive = true
        }
    }

    /// Show or hide the reply quote, re-pinning the body's top to the
    /// quote (when shown) or the bubble (when not). Colors track the
    /// bubble direction: an outgoing bubble is a solid accent fill, so
    /// the quote reads in the on-accent color; an incoming bubble is a
    /// light tint, so the quote uses the quoted sender's accent. An
    /// unavailable target gets a muted, untappable placeholder.
    ///
    /// Called on every `configure` (including reuse), so a recycled
    /// cell that previously showed a quote drops it — and its tap
    /// target — cleanly.
    private func applyReplyQuote(
        _ reply: ChatReplyQuote?,
        direction: MessageDirection,
        onTap: (() -> Void)?
    ) {
        // Always tear down any prior tap target first (reuse safety).
        if let existing = quoteTapRecognizer {
            quoteContainer.removeGestureRecognizer(existing)
            quoteTapRecognizer = nil
        }
        onQuoteTapped = nil

        guard let reply else {
            quoteContainer.isHidden = true
            quoteNameLabel.text = nil
            quoteSnippetLabel.text = nil
            bodyTopToQuoteConstraint.isActive = false
            bodyTopToBubbleConstraint.isActive = true
            return
        }

        quoteContainer.isHidden = false
        bodyTopToBubbleConstraint.isActive = false
        bodyTopToQuoteConstraint.isActive = true

        let onAccent = UIColor(OnymTokens.onAccent)
        if reply.isUnavailable {
            // Muted placeholder — no real sender to attribute.
            let muted = direction == .outgoing
                ? onAccent.withAlphaComponent(0.7)
                : UIColor(OnymTokens.text3)
            quoteBar.backgroundColor = muted
            quoteNameLabel.text = String(localized: "Message")
            quoteNameLabel.textColor = muted
            quoteSnippetLabel.text = String(localized: "Message unavailable")
            quoteSnippetLabel.textColor = muted
        } else {
            let accent = UIColor(reply.accent.color)
            quoteBar.backgroundColor = direction == .outgoing ? onAccent : accent
            quoteNameLabel.text = reply.name
            quoteNameLabel.textColor = direction == .outgoing ? onAccent : accent
            quoteSnippetLabel.text = reply.snippet
            quoteSnippetLabel.textColor = direction == .outgoing
                ? onAccent.withAlphaComponent(0.85)
                : UIColor(OnymTokens.text2)

            // Only an available target is tappable.
            if let onTap {
                onQuoteTapped = onTap
                let tap = UITapGestureRecognizer(target: self, action: #selector(tappedQuote))
                quoteContainer.addGestureRecognizer(tap)
                quoteTapRecognizer = tap
            }
        }
    }

    @objc private func tappedQuote() {
        onQuoteTapped?()
    }

    /// Show or hide the attachment, re-pinning the body (caption) below
    /// it when present. Handles both photos and videos: a video renders
    /// its **poster** (an image attachment) through the same pipeline,
    /// then layers a play button + duration pill on top and routes the
    /// tap to the player. Renders the BlurHash placeholder synchronously,
    /// then swaps in the decrypted poster/image from `ChatImageLoader`.
    /// Reuse-safe via `currentImageSha`.
    private func applyAttachment(
        image: ChatImageAttachment?,
        video: ChatVideoAttachment?,
        imageLoader: ChatImageLoader?,
        onTap: (() -> Void)?
    ) {
        // Tear down the previous aspect constraint + async guard.
        attachmentAspectConstraint?.isActive = false
        attachmentAspectConstraint = nil
        onImageTapped = onTap

        // Ensure any album layout from a recycled cell is torn down.
        albumGridView.isHidden = true
        albumTopToBubbleConstraint.isActive = false
        bodyTopToAlbumConstraint.isActive = false
        albumAspectConstraint?.isActive = false
        albumAspectConstraint = nil

        // Tear down any voice layout from a recycled cell.
        voiceView.isHidden = true
        voiceTopToBubbleConstraint.isActive = false
        bodyTopToVoiceConstraint.isActive = false

        // A video renders its poster; a photo renders itself.
        let attachment = image ?? video?.poster
        guard let attachment else {
            currentImageSha = nil
            attachmentImageView.isHidden = true
            attachmentImageView.image = nil
            playOverlay.isHidden = true
            durationLabel.isHidden = true
            imageTopToBubbleConstraint.isActive = false
            bodyTopToImageConstraint.isActive = false
            attachmentBubbleWidthConstraint.isActive = false
            return
        }

        // Video vs photo affordances: play glyph + duration pill + a11y.
        if let video {
            playOverlay.isHidden = false
            durationLabel.isHidden = false
            durationLabel.text = "  \(Self.formatDuration(video.durationSeconds))  "
            attachmentImageView.accessibilityIdentifier = "chat.bubble.video"
            attachmentImageView.accessibilityLabel = "Video"
        } else {
            playOverlay.isHidden = true
            durationLabel.isHidden = true
            attachmentImageView.accessibilityIdentifier = "chat.bubble.image"
            attachmentImageView.accessibilityLabel = "Photo"
        }

        currentImageSha = attachment.sha256
        attachmentImageView.isHidden = false
        // Image drives the body's top; the normal body-top toggles yield.
        bodyTopToBubbleConstraint.isActive = false
        bodyTopToQuoteConstraint.isActive = false
        imageTopToBubbleConstraint.isActive = true
        bodyTopToImageConstraint.isActive = true
        // Fix the bubble width so the frame is stable from first layout —
        // the aspect ratio below is known from the attachment metadata, so
        // width + ratio fully determine the size before the blob loads.
        attachmentBubbleWidthConstraint.isActive = true

        // Aspect ratio from the sender's decoded dimensions (clamped so a
        // panorama or a sliver doesn't blow up the row).
        let ratio: CGFloat
        if attachment.width > 0 {
            ratio = min(1.6, max(0.5, CGFloat(attachment.height) / CGFloat(attachment.width)))
        } else {
            ratio = 0.75
        }
        let aspect = attachmentImageView.heightAnchor.constraint(
            equalTo: attachmentImageView.widthAnchor, multiplier: ratio
        )
        aspect.isActive = true
        attachmentAspectConstraint = aspect

        // Placeholder now, decrypted image when it loads.
        attachmentImageView.image = Blurhash.decode(
            attachment.blurhash, size: CGSize(width: 32, height: max(1, round(32 * ratio)))
        )
        guard let imageLoader else { return }
        let sha = attachment.sha256
        Task { [weak self] in
            let image = try? await imageLoader.image(for: attachment)
            await MainActor.run {
                guard let self, self.currentImageSha == sha, let image else { return }
                self.attachmentImageView.image = image
            }
        }
    }

    /// Render an album (2+ items) as a grid in place of the single image.
    private func applyAlbum(
        _ items: [ChatMediaAttachment],
        imageLoader: ChatImageLoader?,
        onTapIndex: ((Int) -> Void)?
    ) {
        // Tear down the single-image layout.
        attachmentAspectConstraint?.isActive = false
        attachmentAspectConstraint = nil
        attachmentImageView.isHidden = true
        attachmentImageView.image = nil
        playOverlay.isHidden = true
        durationLabel.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentFailedBadge.isHidden = true
        imageTopToBubbleConstraint.isActive = false
        bodyTopToImageConstraint.isActive = false

        albumGridView.isHidden = false
        bodyTopToBubbleConstraint.isActive = false
        bodyTopToQuoteConstraint.isActive = false
        albumTopToBubbleConstraint.isActive = true
        bodyTopToAlbumConstraint.isActive = true
        attachmentBubbleWidthConstraint.isActive = true

        // Aspect from the row count: one row is a wide 2-up strip, two
        // rows a square-ish 2×2. Known up front, so no jump on load.
        let rows = AlbumGridView.rowCount(for: items.count)
        albumAspectConstraint?.isActive = false
        let aspect = albumGridView.heightAnchor.constraint(
            equalTo: albumGridView.widthAnchor, multiplier: rows == 1 ? 0.5 : 1.0
        )
        aspect.isActive = true
        albumAspectConstraint = aspect

        onAlbumTapIndex = onTapIndex
        albumGridView.configure(items: items, imageLoader: imageLoader) { [weak self] index in
            self?.onAlbumTapIndex?(index)
        }
        voiceView.isHidden = true
        voiceTopToBubbleConstraint.isActive = false
        bodyTopToVoiceConstraint.isActive = false
    }

    /// Render a voice message: the inline `ChatVoiceMessageView` in place of
    /// the image/album, pinned across the top of the bubble. The bubble
    /// takes the fixed attachment width so the player is a consistent size.
    private func applyVoice(
        _ voice: ChatVoiceAttachment,
        voiceLoader: ChatVoiceLoader?,
        direction: MessageDirection,
        status: MessageStatus,
        accent: OnymAccent,
        onFailedTap: (() -> Void)?
    ) {
        // Tear down the single-image + album layouts.
        attachmentAspectConstraint?.isActive = false
        attachmentAspectConstraint = nil
        attachmentImageView.isHidden = true
        attachmentImageView.image = nil
        playOverlay.isHidden = true
        durationLabel.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentFailedBadge.isHidden = true
        imageTopToBubbleConstraint.isActive = false
        bodyTopToImageConstraint.isActive = false
        albumGridView.isHidden = true
        albumTopToBubbleConstraint.isActive = false
        bodyTopToAlbumConstraint.isActive = false
        albumAspectConstraint?.isActive = false
        albumAspectConstraint = nil

        voiceView.isHidden = false
        bodyTopToBubbleConstraint.isActive = false
        bodyTopToQuoteConstraint.isActive = false
        voiceTopToBubbleConstraint.isActive = true
        bodyTopToVoiceConstraint.isActive = true
        attachmentBubbleWidthConstraint.isActive = true

        let tint = direction == .outgoing
            ? UIColor(OnymTokens.onAccent)
            : UIColor(accent.color)
        voiceView.configure(
            voice: voice,
            loader: voiceLoader,
            tint: tint,
            trackColor: tint.withAlphaComponent(0.3),
            status: status,
            direction: direction,
            onFailedTap: onFailedTap
        )
    }

    // MARK: - Swipe to reply

    private func installSwipeToReply() {
        replyHint.translatesAutoresizingMaskIntoConstraints = false
        replyHint.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
        replyHint.tintColor = UIColor(OnymTokens.text3)
        replyHint.contentMode = .scaleAspectFit
        replyHint.alpha = 0
        replyHint.accessibilityIdentifier = "chat.bubble.reply_hint"
        contentView.addSubview(replyHint)
        NSLayoutConstraint.activate([
            replyHint.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            replyHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            replyHint.widthAnchor.constraint(equalToConstant: 22),
            replyHint.heightAnchor.constraint(equalToConstant: 22),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        pan.delegate = self
        contentView.addGestureRecognizer(pan)
        swipePan = pan
    }

    @objc private func handleSwipePan(_ pan: UIPanGestureRecognizer) {
        let tx = pan.translation(in: contentView).x
        switch pan.state {
        case .began:
            swipeArmed = false
            swipeHaptic.prepare()
        case .changed:
            // Leftward drag only; clamp travel so the bubble can't be
            // dragged off-screen and the "armed" point reads as a wall.
            let drag = min(swipeMaxTravel, max(0, -tx))
            applySwipeTranslation(drag)
            let progress = min(1, drag / swipeReplyThreshold)
            replyHint.alpha = progress
            let scale = 0.6 + 0.4 * progress
            replyHint.transform = CGAffineTransform(scaleX: scale, y: scale)
            if drag >= swipeReplyThreshold, !swipeArmed {
                swipeArmed = true
                swipeHaptic.impactOccurred()   // one-shot "armed" tick
            } else if drag < swipeReplyThreshold {
                swipeArmed = false
            }
        case .ended, .cancelled, .failed:
            let fire = swipeArmed && pan.state == .ended
            swipeArmed = false
            UIView.animate(
                withDuration: 0.25, delay: 0,
                usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5,
                options: [.allowUserInteraction]
            ) {
                self.applySwipeTranslation(0)
                self.replyHint.alpha = 0
                self.replyHint.transform = .identity
            }
            if fire { onSwipeToReply?() }
        default:
            break
        }
    }

    /// Translate the moving parts of the row by `dx` points to the
    /// left. The reply hint stays put at the trailing edge and is
    /// revealed by the gap the bubble opens up.
    private func applySwipeTranslation(_ dx: CGFloat) {
        let t = CGAffineTransform(translationX: -dx, y: 0)
        bubble.transform = t
        statusImageView.transform = t
        statusImageView2.transform = t
        failureLabel.transform = t
        nameLabel.transform = t
    }

    private func resetSwipeState() {
        swipeArmed = false
        applySwipeTranslation(0)
        replyHint.alpha = 0
        replyHint.transform = .identity
    }

    /// Brief background pulse on the bubble — used by the host to draw
    /// the eye to a message after scrolling to it from a tapped quote.
    func flashHighlight() {
        let original = bubble.backgroundColor
        let highlight = UIColor(OnymTokens.text3).withAlphaComponent(0.5)
        UIView.animate(withDuration: 0.18, animations: {
            self.bubble.backgroundColor = highlight
        }, completion: { _ in
            UIView.animate(withDuration: 0.45) {
                self.bubble.backgroundColor = original
            }
        })
    }

    private func applyStatus(_ status: MessageStatus, failureReason: SendFailureReason?) {
        statusImageView.isHidden = false
        // The second checkmark only shows for the double-check states;
        // hide it by default and let `.delivered` / `.read` reveal it.
        statusImageView2.isHidden = true
        // Default shape: no explanation, status glyph drives the cell
        // bottom. `.failed` overrides below. Deactivate before
        // activate so the two bottom anchors never conflict.
        failureBottomConstraint.isActive = false
        failureLabel.isHidden = true
        failureLabel.text = nil
        statusBottomConstraint.isActive = true
        switch status {
        case .pending:
            statusImageView.image = UIImage(systemName: "clock")
            statusImageView.tintColor = UIColor(OnymTokens.text3)
            statusImageView.accessibilityLabel = "Sending"
        case .sent:
            statusImageView.image = UIImage(systemName: "checkmark")
            statusImageView.tintColor = UIColor(OnymTokens.text3)
            statusImageView.accessibilityLabel = "Sent"
        case .delivered:
            applyDoubleCheck(tint: UIColor(OnymTokens.text3))
            statusImageView.accessibilityLabel = "Delivered"
        case .read:
            applyDoubleCheck(tint: UIColor(OnymAccent.blue.color))
            statusImageView.accessibilityLabel = "Read"
        case .failed:
            statusImageView.image = UIImage(systemName: "exclamationmark.circle.fill")
            statusImageView.tintColor = UIColor(OnymTokens.red)
            statusImageView.accessibilityLabel = "Failed — tap to retry"
            let cause = failureReason?.explanation ?? "Message not delivered."
            failureLabel.text = cause + " Tap the message to retry."
            failureLabel.isHidden = false
            statusBottomConstraint.isActive = false
            failureBottomConstraint.isActive = true
        case .received:
            // Outgoing rows never carry .received; hide as a
            // defensive default if a bad row somehow lands here.
            statusImageView.isHidden = true
        }
    }

    /// Render both checkmarks in `tint` — gray for `.delivered`, the
    /// accent for `.read`.
    private func applyDoubleCheck(tint: UIColor) {
        let check = UIImage(systemName: "checkmark")
        statusImageView.image = check
        statusImageView.tintColor = tint
        statusImageView2.image = check
        statusImageView2.tintColor = tint
        statusImageView2.isHidden = false
    }

    @objc private func tappedBubble() {
        onRetryRequested?()
    }

    /// Test seam — fires the same handler the bubble's
    /// `UITapGestureRecognizer` would on a real touch. Without
    /// this, tests would need runtime-private hooks to synthesize
    /// the tap; this single internal method keeps the rest of
    /// the cell API private. Marked `internal` so `@testable import`
    /// can reach it.
    #if DEBUG
    func simulateBubbleTapForTest() {
        tappedBubble()
    }

    /// Test seam for the quote tap — fires the same handler the quote's
    /// recognizer would, and returns whether a tap target was actually
    /// installed (so tests can assert an unavailable quote is inert).
    @discardableResult
    func simulateQuoteTapForTest() -> Bool {
        let installed = quoteTapRecognizer != nil
        tappedQuote()
        return installed
    }

    /// Test seam for the swipe-to-reply gesture — fires the armed-reply
    /// callback the same way a past-threshold drag-release would.
    func simulateSwipeToReplyForTest() {
        onSwipeToReply?()
    }
    #endif

    private func buildBubble() {
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 14
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        // Hug the text horizontally with a decisive priority so a text
        // bubble shrinks to fit its content. Without this the label sits at
        // the default hugging (251), tying with the hidden media siblings
        // (image/album/voice) that are also pinned edge-to-edge on the
        // bubble — autolayout resolves the tie inconsistently, so *some*
        // short text bubbles stretch toward the 75% cap. `.defaultHigh`
        // (750) beats those siblings while still yielding to the fixed
        // 75%-width constraint (1000) a real media message installs.
        bodyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        bubble.addSubview(bodyLabel)

        attachmentImageView.translatesAutoresizingMaskIntoConstraints = false
        attachmentImageView.contentMode = .scaleAspectFill
        attachmentImageView.clipsToBounds = true
        attachmentImageView.layer.cornerRadius = 10
        attachmentImageView.layer.cornerCurve = .continuous
        attachmentImageView.isHidden = true
        attachmentImageView.isUserInteractionEnabled = true
        attachmentImageView.accessibilityIdentifier = "chat.bubble.image"
        attachmentImageView.isAccessibilityElement = true
        attachmentImageView.accessibilityLabel = "Photo"
        let imageTap = UITapGestureRecognizer(target: self, action: #selector(tappedImage))
        attachmentImageView.addGestureRecognizer(imageTap)
        imageTapRecognizer = imageTap
        bubble.addSubview(attachmentImageView)

        albumGridView.translatesAutoresizingMaskIntoConstraints = false
        albumGridView.isHidden = true
        bubble.addSubview(albumGridView)

        voiceView.isHidden = true
        bubble.addSubview(voiceView)

        // Video-only overlays, layered on top of the poster. Hidden for
        // photos; toggled in `applyAttachment`.
        playOverlay.translatesAutoresizingMaskIntoConstraints = false
        playOverlay.contentMode = .scaleAspectFit
        playOverlay.tintColor = .white
        playOverlay.image = UIImage(
            systemName: "play.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        )
        playOverlay.isHidden = true
        // Soft shadow so the glyph reads over a bright poster.
        playOverlay.layer.shadowColor = UIColor.black.cgColor
        playOverlay.layer.shadowOpacity = 0.4
        playOverlay.layer.shadowRadius = 4
        playOverlay.layer.shadowOffset = .zero
        attachmentImageView.addSubview(playOverlay)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .center
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        durationLabel.layer.cornerRadius = 4
        durationLabel.layer.cornerCurve = .continuous
        durationLabel.clipsToBounds = true
        durationLabel.isHidden = true
        attachmentImageView.addSubview(durationLabel)

        // Upload spinner (pending) over a dimming scrim so it reads on
        // any poster. Both hidden unless the send is in flight.
        attachmentSpinner.translatesAutoresizingMaskIntoConstraints = false
        attachmentSpinner.color = .white
        attachmentSpinner.hidesWhenStopped = true
        attachmentImageView.addSubview(attachmentSpinner)

        attachmentFailedBadge.translatesAutoresizingMaskIntoConstraints = false
        attachmentFailedBadge.contentMode = .scaleAspectFit
        attachmentFailedBadge.tintColor = UIColor(OnymTokens.red)
        attachmentFailedBadge.image = UIImage(
            systemName: "exclamationmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        )
        attachmentFailedBadge.isHidden = true
        attachmentFailedBadge.layer.shadowColor = UIColor.black.cgColor
        attachmentFailedBadge.layer.shadowOpacity = 0.4
        attachmentFailedBadge.layer.shadowRadius = 4
        attachmentFailedBadge.layer.shadowOffset = .zero
        attachmentImageView.addSubview(attachmentFailedBadge)

        NSLayoutConstraint.activate([
            playOverlay.centerXAnchor.constraint(equalTo: attachmentImageView.centerXAnchor),
            playOverlay.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),
            playOverlay.widthAnchor.constraint(equalToConstant: 48),
            playOverlay.heightAnchor.constraint(equalToConstant: 48),
            durationLabel.trailingAnchor.constraint(
                equalTo: attachmentImageView.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(
                equalTo: attachmentImageView.bottomAnchor, constant: -6),
            durationLabel.heightAnchor.constraint(equalToConstant: 16),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            attachmentSpinner.centerXAnchor.constraint(equalTo: attachmentImageView.centerXAnchor),
            attachmentSpinner.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),
            attachmentFailedBadge.centerXAnchor.constraint(equalTo: attachmentImageView.centerXAnchor),
            attachmentFailedBadge.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),
            attachmentFailedBadge.widthAnchor.constraint(equalToConstant: 44),
            attachmentFailedBadge.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Show the upload spinner (`.pending`) or the failed badge
    /// (`.failed`) over an outgoing attachment, and hide the play glyph
    /// while a send is in flight so it doesn't compete with the spinner.
    /// No-op (all hidden) for incoming rows, sent rows, and text.
    private func applyAttachmentSendState(_ message: ChatMessage) {
        let hasAttachment = message.imageAttachment != nil || message.videoAttachment != nil
        guard hasAttachment, message.direction == .outgoing else {
            attachmentSpinner.stopAnimating()
            attachmentFailedBadge.isHidden = true
            return
        }
        switch message.status {
        case .pending:
            attachmentSpinner.startAnimating()
            attachmentFailedBadge.isHidden = true
            playOverlay.isHidden = true
        case .failed:
            attachmentSpinner.stopAnimating()
            attachmentFailedBadge.isHidden = false
            playOverlay.isHidden = true
        default:
            attachmentSpinner.stopAnimating()
            attachmentFailedBadge.isHidden = true
        }
    }

    /// Formats a duration in seconds as `m:ss` (e.g. `1:07`, `0:09`).
    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func tappedImage() {
        onImageTapped?()
    }

    private func buildQuote() {
        quoteContainer.translatesAutoresizingMaskIntoConstraints = false
        quoteContainer.isHidden = true
        quoteContainer.accessibilityIdentifier = "chat.bubble.quote"
        bubble.addSubview(quoteContainer)

        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.layer.cornerRadius = 1.5
        quoteBar.layer.cornerCurve = .continuous
        quoteContainer.addSubview(quoteBar)

        let nameBase = UIFont.systemFont(ofSize: 12, weight: .semibold)
        quoteNameLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: nameBase)
        quoteNameLabel.adjustsFontForContentSizeCategory = true
        quoteNameLabel.numberOfLines = 1
        quoteNameLabel.lineBreakMode = .byTruncatingTail
        quoteNameLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteNameLabel.accessibilityIdentifier = "chat.bubble.quote.name"
        quoteContainer.addSubview(quoteNameLabel)

        let snippetBase = UIFont.systemFont(ofSize: 13, weight: .regular)
        quoteSnippetLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: snippetBase)
        quoteSnippetLabel.adjustsFontForContentSizeCategory = true
        quoteSnippetLabel.numberOfLines = 1
        quoteSnippetLabel.lineBreakMode = .byTruncatingTail
        quoteSnippetLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteSnippetLabel.accessibilityIdentifier = "chat.bubble.quote.snippet"
        quoteContainer.addSubview(quoteSnippetLabel)
    }

    private func buildStatusIndicator() {
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.contentMode = .scaleAspectFit
        statusImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 11,
            weight: .semibold
        )
        statusImageView.isHidden = true
        statusImageView.accessibilityIdentifier = "chat.bubble.status"
        // Expose the delivery-status glyph (Sending / Sent / Delivered /
        // Read via `accessibilityLabel`) to VoiceOver + UI tests.
        statusImageView.isAccessibilityElement = true
        contentView.addSubview(statusImageView)

        statusImageView2.translatesAutoresizingMaskIntoConstraints = false
        statusImageView2.contentMode = .scaleAspectFit
        statusImageView2.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 11,
            weight: .semibold
        )
        statusImageView2.isHidden = true
        statusImageView2.accessibilityIdentifier = "chat.bubble.status2"
        contentView.addSubview(statusImageView2)

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        let base = UIFont.systemFont(ofSize: 12, weight: .regular)
        failureLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .right
        failureLabel.textColor = UIColor(OnymTokens.red)
        failureLabel.isHidden = true
        failureLabel.accessibilityIdentifier = "chat.bubble.failure_reason"
        contentView.addSubview(failureLabel)
    }

    private func buildNameLabel() {
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        // Scaled so it tracks Dynamic Type — `systemFont` alone wouldn't.
        let base = UIFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isHidden = true
        nameLabel.accessibilityIdentifier = "chat.bubble.sender"
        // Added after `bubble` so `contentView.subviews.first` stays the
        // bubble — the alignment-introspection tests rely on that.
        contentView.addSubview(nameLabel)
    }

    private func layoutBubble() {
        let edgeInset: CGFloat = 12
        let oppositeGap: CGFloat = 56

        bubbleBottomConstraint = bubble.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -4
        )
        statusBottomConstraint = contentView.bottomAnchor.constraint(
            equalTo: statusImageView.bottomAnchor, constant: 4
        )
        failureBottomConstraint = contentView.bottomAnchor.constraint(
            equalTo: failureLabel.bottomAnchor, constant: 4
        )

        // Bubble-top toggle. `bubbleTopToContentConstraint` is the
        // default (no header); `applyNameHeader` swaps to
        // `bubbleTopToNameConstraint` + `nameTopConstraint` when a
        // header shows. Exactly one top path is active at a time.
        bubbleTopToContentConstraint = bubble.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: 4
        )
        nameTopConstraint = nameLabel.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: 5
        )
        bubbleTopToNameConstraint = bubble.topAnchor.constraint(
            equalTo: nameLabel.bottomAnchor, constant: 3
        )

        // Body-top toggle — `configure` activates exactly one depending
        // on whether a reply quote is shown.
        bodyTopToBubbleConstraint = bodyLabel.topAnchor.constraint(
            equalTo: bubble.topAnchor, constant: 8
        )
        bodyTopToQuoteConstraint = bodyLabel.topAnchor.constraint(
            equalTo: quoteContainer.bottomAnchor, constant: 6
        )

        // Image-attachment toggle constraints (inactive by default).
        imageTopToBubbleConstraint = attachmentImageView.topAnchor.constraint(
            equalTo: bubble.topAnchor, constant: 4
        )
        bodyTopToImageConstraint = bodyLabel.topAnchor.constraint(
            equalTo: attachmentImageView.bottomAnchor, constant: 6
        )
        // Fixed bubble width for attachment messages (toggled in
        // `applyAttachment`). Equal — not ≤ — so the frame is known up
        // front and doesn't grow when the blob loads.
        attachmentBubbleWidthConstraint = bubble.widthAnchor.constraint(
            equalTo: contentView.widthAnchor, multiplier: maxWidthFraction
        )

        // Album grid toggle constraints (parallel to the single image).
        albumTopToBubbleConstraint = albumGridView.topAnchor.constraint(
            equalTo: bubble.topAnchor, constant: 4
        )
        bodyTopToAlbumConstraint = bodyLabel.topAnchor.constraint(
            equalTo: albumGridView.bottomAnchor, constant: 6
        )

        // Voice player toggle constraints (parallel to the image/album).
        voiceTopToBubbleConstraint = voiceView.topAnchor.constraint(
            equalTo: bubble.topAnchor, constant: 6
        )
        bodyTopToVoiceConstraint = bodyLabel.topAnchor.constraint(
            equalTo: voiceView.bottomAnchor, constant: 2
        )

        NSLayoutConstraint.activate([
            voiceView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            voiceView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            albumGridView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
            albumGridView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -4),
            attachmentImageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
            attachmentImageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -4),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor,
                multiplier: maxWidthFraction
            ),
            bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bodyLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),

            // Reply quote — pinned across the top of the bubble. Only
            // drives the body's top when `bodyTopToQuoteConstraint` is
            // active (i.e. a quote is shown); otherwise it's hidden and
            // its labels are cleared so it adds no height.
            quoteContainer.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            quoteContainer.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            quoteContainer.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            quoteBar.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: quoteContainer.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),

            quoteNameLabel.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 6),
            quoteNameLabel.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor),
            quoteNameLabel.topAnchor.constraint(equalTo: quoteContainer.topAnchor),

            quoteSnippetLabel.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 6),
            quoteSnippetLabel.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor),
            quoteSnippetLabel.topAnchor.constraint(equalTo: quoteNameLabel.bottomAnchor, constant: 1),
            quoteSnippetLabel.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor),

            // Name header aligns to the (incoming) bubble's leading edge
            // with a small indent, and never runs into the trailing gap.
            // Only laid out as visible when `nameTopConstraint` is active.
            nameLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -oppositeGap
            ),

            // Status indicator sits in the gap below the bubble,
            // trailing-aligned. Always positioned relative to the
            // bubble; only the cell-bottom anchor differs between
            // directions (see `bubbleBottomConstraint` vs
            // `statusBottomConstraint`).
            statusImageView.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
            statusImageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalToConstant: 14),

            // Second checkmark, offset left so the pair overlaps into a
            // double-check. Only visible for .delivered / .read.
            statusImageView2.centerYAnchor.constraint(equalTo: statusImageView.centerYAnchor),
            statusImageView2.trailingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: -5),
            statusImageView2.widthAnchor.constraint(equalToConstant: 14),
            statusImageView2.heightAnchor.constraint(equalToConstant: 14),

            // Failure explanation sits left of the red bang, growing
            // leftward/downward as needed. Only participates in the
            // cell's height when `failureBottomConstraint` is active
            // (i.e. status == .failed on an outgoing row).
            failureLabel.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
            failureLabel.trailingAnchor.constraint(equalTo: statusImageView.leadingAnchor, constant: -6),
            failureLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: edgeInset),
        ])

        // Outgoing pair — trailing-pinned, leading has the
        // opposite-edge gap. Activating the leading-`==` from the
        // other pair simultaneously would conflict with this gap;
        // `configure(message:)` toggles the pairs together.
        outgoingConstraints = [
            bubble.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -edgeInset
            ),
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: oppositeGap
            ),
        ]
        incomingConstraints = [
            bubble.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: edgeInset
            ),
            bubble.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -oppositeGap
            ),
        ]
        // Default to leading (incoming) + no header — `configure`
        // overrides before the cell is shown, but the default keeps
        // the cell layout-valid even if a configurer skips us.
        NSLayoutConstraint.activate(incomingConstraints)
        bubbleBottomConstraint.isActive = true
        bubbleTopToContentConstraint.isActive = true
        bodyTopToBubbleConstraint.isActive = true
    }
}

// UIView already conforms to `UIGestureRecognizerDelegate` and ships
// these as overridable methods, so we extend (not re-conform) and mark
// both `override`. The cell is the swipe pan's own delegate.
extension ChatBubbleCell {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipePan else { return true }
        // Claim only a clearly leftward, mostly-horizontal drag so the
        // table's vertical scroll keeps working and the controller's
        // rightward full-width back-pan is unaffected.
        let velocity = swipePan.velocity(in: contentView)
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }

    override func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Coexist with the scroll view's pan — `shouldBegin` already
        // restricts us to horizontal drags, so the two don't fight in
        // practice.
        true
    }
}
