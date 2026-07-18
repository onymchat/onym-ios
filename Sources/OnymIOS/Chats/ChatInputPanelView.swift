import SwiftUI
import UIKit

/// Bottom input panel for the chat thread. Hosts the message
/// composer's `UITextView`, a Send button, and the hairline divider
/// that separates the panel from the message list.
///
/// Height behavior — the text view grows with content up to a
/// 3-line cap (`maxLineCount`); beyond that it scrolls internally.
/// Single-line state hugs `minTextViewHeight` so the panel never
/// shrinks below a thumb-tappable target.
///
/// PR 7 scope: layout + keyboard avoidance + enabled-state toggle.
/// **No real send wiring** — `onSendTapped` clears the text but the
/// host doesn't do anything else with the body. PR 8 hooks the
/// closure to `SendMessageInteractor`.
final class ChatInputPanelView: UIView {
    /// Invoked when the user taps Send. Receives the current text
    /// trimmed of leading/trailing whitespace. PR 8 will wire this
    /// to `SendMessageInteractor.send`.
    var onSendTapped: ((String) -> Void)?
    /// Tapped the attach button. The host presents the combined
    /// photo + video picker.
    var onAttachTapped: (() -> Void)?

    /// A voice message finished recording (mic released past the minimum
    /// hold, not cancelled). Receives the recorded `.m4a` file URL; the
    /// host encrypts + uploads it via `SendMessageInteractor.sendVoice`.
    var onSendVoiceTapped: ((URL) -> Void)?

    /// Tapped Send while media is staged in the preview strip. The host
    /// sends the staged items (as one album) and clears the strip.
    var onSendMediaTapped: (() -> Void)?

    /// Tapped the ✕ on a staged item — the host removes it from the
    /// pending selection and re-pushes via `setPendingMedia`.
    var onRemovePendingMedia: ((UUID) -> Void)?

    /// Whether any media is staged in the preview strip.
    private var hasPendingMedia = false

    /// Invoked when the user taps the reply banner's cancel button.
    /// The host clears its armed reply target and calls
    /// `clearReplyBanner()`.
    var onCancelReply: (() -> Void)?

    var text: String {
        // `UITextView.text` is bridged as `String!`, but Swift
        // still requires unwrap for chained access on the
        // surface. Keep the `?? ""` so the compiler is happy and
        // we don't have a stray force-unwrap site.
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            // Re-evaluate height + send-button state + placeholder
            // so external writes look the same as user typing.
            refreshAfterTextChange()
        }
    }

    /// Cap on the auto-grow behavior. Past this many lines the
    /// text view scrolls internally instead of pushing the
    /// message list further up.
    static let maxLineCount = 3

    private let topDivider = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    /// Voice-record button, shown on the trailing edge when the composer is
    /// empty (no text, no staged media). Held to record; released to send.
    private let micButton = UIButton(type: .system)
    /// Single leading attach button (paperclip) → combined photo/video picker.
    private let attachButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint!

    // Voice recording. The recorder captures to a temp `.m4a`; the overlay
    // (red dot + elapsed timer + "slide to cancel") covers the text field
    // while a recording is in flight. A leftward slide past
    // `cancelSlideThreshold` arms cancel-on-release.
    private let voiceRecorder = ChatVoiceRecorder()
    private let recordingOverlay = UIView()
    private let recordingDot = UIView()
    private let recordingTimeLabel = UILabel()
    private let recordingHintLabel = UILabel()
    private var recordingTimer: Timer?
    private var isRecording = false
    private var recordingWillCancel = false
    /// Leftward drag (points) past which releasing cancels instead of sends.
    private let cancelSlideThreshold: CGFloat = 80

    // Reply banner — shown above the composer while a reply is armed.
    // Accent bar + "Replying to {name}" + a one-line snippet + a
    // cancel button. Hidden by default; `showReplyBanner` reveals it
    // and re-pins the text view's top below it.
    private let replyBanner = UIView()
    private let replyBannerBar = UIView()
    private let replyBannerTitle = UILabel()
    private let replyBannerSnippet = UILabel()
    private let replyCancelButton = UIButton(type: .system)
    private var textViewTopToPanelConstraint: NSLayoutConstraint!
    private var textViewTopToBannerConstraint: NSLayoutConstraint!
    private var textViewTopToStripConstraint: NSLayoutConstraint!
    private var replyBannerTopToPanelConstraint: NSLayoutConstraint!
    private var replyBannerTopToStripConstraint: NSLayoutConstraint!

    // Media preview strip — a horizontal row of staged image/video
    // thumbnails (each with a ✕ to remove) shown above the reply banner
    // / text field once media is picked. Confirming with Send fires
    // `onSendMediaTapped`. Hidden (height 0) when nothing is staged.
    private let mediaStrip = UIScrollView()
    private let mediaStripStack = UIStackView()
    private var mediaStripHeightConstraint: NSLayoutConstraint!
    /// Height of a staged thumbnail (square) in the strip.
    private let mediaThumbSize: CGFloat = 60
    private var replyBannerShown = false

    /// Height for exactly `lines` worth of text plus the text
    /// view's vertical insets. Drives both the natural empty-state
    /// floor (`lines = 1`) and the auto-grow cap
    /// (`lines = maxLineCount`). Computed dynamically so Dynamic
    /// Type changes the floor too.
    func intrinsicHeight(forLines lines: Int) -> CGFloat {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let lineHeight = ceil(font.lineHeight)
        let insets = textView.textContainerInset.top + textView.textContainerInset.bottom
        return lineHeight * CGFloat(lines) + insets
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The composer floats on the chat background — the attach/mic
        // circles and the text-field pill are the only filled chrome, so
        // they read as separated buttons rather than sitting inside a bar.
        backgroundColor = UIColor(OnymTokens.bg)
        buildSubviews()
        buildReplyBanner()
        buildMediaStrip()
        layoutSubviewsLocal()
        refreshAfterTextChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Build

    private func buildSubviews() {
        topDivider.backgroundColor = UIColor(OnymTokens.hairline)
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor(OnymTokens.text)
        // Mid-grey pill on the near-black background (matches the attach /
        // mic circles, distinct from the panel behind them).
        textView.backgroundColor = UIColor(OnymTokens.surface3)
        textView.layer.cornerRadius = 20
        textView.layer.cornerCurve = .continuous
        // Taller vertical inset so the single-line pill matches the 40pt
        // attach / mic circle height; roomier horizontal inset for the pill.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "chat.input.textview"
        addSubview(textView)

        // UITextView has no native placeholder. Overlay a label
        // anchored to the same insets the text container uses and
        // hide it when text is present.
        placeholderLabel.text = "Message"
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = UIColor(OnymTokens.text3)
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)

        // Send: a filled accent circle with a white up-arrow — same 40pt
        // circular chrome as the attach / mic buttons, clearly separated
        // from the text-field pill.
        var sendConfig = UIButton.Configuration.plain()
        sendConfig.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        )
        sendConfig.contentInsets = .zero
        sendButton.configuration = sendConfig
        sendButton.tintColor = UIColor(OnymTokens.onAccent)
        sendButton.backgroundColor = UIColor(OnymAccent.blue.color)
        sendButton.layer.cornerRadius = 20
        sendButton.layer.cornerCurve = .continuous
        sendButton.addTarget(self, action: #selector(tappedSend), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.accessibilityIdentifier = "chat.input.send"
        sendButton.accessibilityLabel = "Send"
        addSubview(sendButton)

        // Mic (voice-record) button — a circular button on the trailing
        // edge shown when the composer is empty. Held to record; released
        // past the minimum hold to send; slid left to cancel.
        var micConfig = UIButton.Configuration.plain()
        micConfig.image = UIImage(
            systemName: "mic.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        )
        micConfig.contentInsets = .zero
        micButton.configuration = micConfig
        micButton.tintColor = UIColor(OnymTokens.text2)
        micButton.backgroundColor = UIColor(OnymTokens.surface3)
        micButton.layer.cornerRadius = 20
        micButton.layer.cornerCurve = .continuous
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.accessibilityIdentifier = "chat.input.mic"
        micButton.accessibilityLabel = "Record voice message"
        let micHold = UILongPressGestureRecognizer(
            target: self, action: #selector(handleMicHold(_:))
        )
        micHold.minimumPressDuration = 0.2
        micButton.addGestureRecognizer(micHold)
        // Under the UI-test loopback harness a press-and-hold can't be
        // driven, so a plain tap sends a canned voice message. No-op in a
        // normal build (see the guard in `tappedMicDebug`).
        micButton.addTarget(self, action: #selector(tappedMicDebug), for: .touchUpInside)
        addSubview(micButton)

        // Single leading attach button (paperclip) → combined picker,
        // styled as a circular button to match the composer's round chrome.
        var attachConfig = UIButton.Configuration.plain()
        attachConfig.image = UIImage(
            systemName: "paperclip",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        )
        attachConfig.contentInsets = .zero
        attachButton.configuration = attachConfig
        attachButton.tintColor = UIColor(OnymTokens.text2)
        attachButton.backgroundColor = UIColor(OnymTokens.surface3)
        attachButton.layer.cornerRadius = 20
        attachButton.layer.cornerCurve = .continuous
        attachButton.addTarget(self, action: #selector(tappedAttach), for: .touchUpInside)
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.accessibilityIdentifier = "chat.input.attach"
        attachButton.accessibilityLabel = "Attach photo or video"
        addSubview(attachButton)

        buildRecordingOverlay()
    }

    /// The record-time overlay that covers the text field: a pulsing red
    /// dot, an elapsed `m:ss` timer, and a "slide to cancel" hint. Hidden
    /// until a recording starts.
    private func buildRecordingOverlay() {
        recordingOverlay.translatesAutoresizingMaskIntoConstraints = false
        recordingOverlay.backgroundColor = UIColor(OnymTokens.surface3)
        recordingOverlay.layer.cornerRadius = 20
        recordingOverlay.layer.cornerCurve = .continuous
        recordingOverlay.isHidden = true
        recordingOverlay.accessibilityIdentifier = "chat.input.recording"
        addSubview(recordingOverlay)

        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        recordingDot.backgroundColor = UIColor.systemRed
        recordingDot.layer.cornerRadius = 4
        recordingOverlay.addSubview(recordingDot)

        recordingTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        recordingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        recordingTimeLabel.textColor = UIColor(OnymTokens.text)
        recordingTimeLabel.text = "0:00"
        recordingOverlay.addSubview(recordingTimeLabel)

        recordingHintLabel.translatesAutoresizingMaskIntoConstraints = false
        recordingHintLabel.font = .preferredFont(forTextStyle: .subheadline)
        recordingHintLabel.textColor = UIColor(OnymTokens.text3)
        recordingHintLabel.text = "‹ slide to cancel"
        recordingHintLabel.textAlignment = .center
        recordingOverlay.addSubview(recordingHintLabel)

        NSLayoutConstraint.activate([
            recordingDot.leadingAnchor.constraint(equalTo: recordingOverlay.leadingAnchor, constant: 14),
            recordingDot.centerYAnchor.constraint(equalTo: recordingOverlay.centerYAnchor),
            recordingDot.widthAnchor.constraint(equalToConstant: 8),
            recordingDot.heightAnchor.constraint(equalToConstant: 8),

            recordingTimeLabel.leadingAnchor.constraint(equalTo: recordingDot.trailingAnchor, constant: 8),
            recordingTimeLabel.centerYAnchor.constraint(equalTo: recordingOverlay.centerYAnchor),

            recordingHintLabel.centerXAnchor.constraint(equalTo: recordingOverlay.centerXAnchor),
            recordingHintLabel.centerYAnchor.constraint(equalTo: recordingOverlay.centerYAnchor),
        ])
    }

    private func buildReplyBanner() {
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.isHidden = true
        replyBanner.accessibilityIdentifier = "chat.input.reply_banner"
        addSubview(replyBanner)

        replyBannerBar.translatesAutoresizingMaskIntoConstraints = false
        replyBannerBar.layer.cornerRadius = 1.5
        replyBannerBar.layer.cornerCurve = .continuous
        replyBanner.addSubview(replyBannerBar)

        let titleBase = UIFont.systemFont(ofSize: 12, weight: .semibold)
        replyBannerTitle.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: titleBase)
        replyBannerTitle.adjustsFontForContentSizeCategory = true
        replyBannerTitle.numberOfLines = 1
        replyBannerTitle.lineBreakMode = .byTruncatingTail
        replyBannerTitle.translatesAutoresizingMaskIntoConstraints = false
        replyBannerTitle.accessibilityIdentifier = "chat.input.reply_banner.title"
        replyBanner.addSubview(replyBannerTitle)

        let snippetBase = UIFont.systemFont(ofSize: 13, weight: .regular)
        replyBannerSnippet.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: snippetBase)
        replyBannerSnippet.adjustsFontForContentSizeCategory = true
        replyBannerSnippet.numberOfLines = 1
        replyBannerSnippet.lineBreakMode = .byTruncatingTail
        replyBannerSnippet.textColor = UIColor(OnymTokens.text2)
        replyBannerSnippet.translatesAutoresizingMaskIntoConstraints = false
        replyBannerSnippet.accessibilityIdentifier = "chat.input.reply_banner.snippet"
        replyBanner.addSubview(replyBannerSnippet)

        var cancelConfig = UIButton.Configuration.plain()
        cancelConfig.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        )
        cancelConfig.contentInsets = .zero
        replyCancelButton.configuration = cancelConfig
        replyCancelButton.tintColor = UIColor(OnymTokens.text3)
        replyCancelButton.addTarget(self, action: #selector(tappedCancelReply), for: .touchUpInside)
        replyCancelButton.translatesAutoresizingMaskIntoConstraints = false
        replyCancelButton.accessibilityIdentifier = "chat.input.reply_banner.cancel"
        replyCancelButton.accessibilityLabel = "Cancel reply"
        replyBanner.addSubview(replyCancelButton)
    }

    private func buildMediaStrip() {
        mediaStrip.translatesAutoresizingMaskIntoConstraints = false
        mediaStrip.showsHorizontalScrollIndicator = false
        mediaStrip.clipsToBounds = false
        mediaStrip.isHidden = true
        mediaStrip.accessibilityIdentifier = "chat.input.media_strip"
        addSubview(mediaStrip)

        mediaStripStack.translatesAutoresizingMaskIntoConstraints = false
        mediaStripStack.axis = .horizontal
        mediaStripStack.spacing = 8
        mediaStripStack.alignment = .center
        mediaStrip.addSubview(mediaStripStack)
        NSLayoutConstraint.activate([
            mediaStripStack.topAnchor.constraint(equalTo: mediaStrip.contentLayoutGuide.topAnchor),
            mediaStripStack.bottomAnchor.constraint(equalTo: mediaStrip.contentLayoutGuide.bottomAnchor),
            mediaStripStack.leadingAnchor.constraint(equalTo: mediaStrip.contentLayoutGuide.leadingAnchor),
            mediaStripStack.trailingAnchor.constraint(equalTo: mediaStrip.contentLayoutGuide.trailingAnchor),
            mediaStripStack.heightAnchor.constraint(equalTo: mediaStrip.frameLayoutGuide.heightAnchor),
        ])
    }

    /// Stage (or restage) the picked media shown in the preview strip.
    /// Pass an empty array to hide the strip. Each tile carries a stable
    /// id so a ✕ tap can report which item to drop.
    func setPendingMedia(_ items: [(id: UUID, thumbnail: UIImage)]) {
        mediaStripStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hasPendingMedia = !items.isEmpty
        for item in items {
            mediaStripStack.addArrangedSubview(makeThumbTile(id: item.id, image: item.thumbnail))
        }
        mediaStrip.isHidden = items.isEmpty
        mediaStripHeightConstraint.constant = items.isEmpty ? 0 : mediaThumbSize + 12
        updateTopChain()
        refreshAfterTextChange()   // re-evaluate the Send button's enabled state
    }

    private func makeThumbTile(id: UUID, image: UIImage) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.layer.cornerCurve = .continuous
        container.addSubview(imageView)

        let remove = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        )
        config.contentInsets = .zero
        remove.configuration = config
        remove.tintColor = .white
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.accessibilityIdentifier = "chat.input.media_strip.remove"
        remove.addAction(UIAction { [weak self] _ in self?.onRemovePendingMedia?(id) }, for: .touchUpInside)
        container.addSubview(remove)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: mediaThumbSize),
            imageView.heightAnchor.constraint(equalToConstant: mediaThumbSize),
            remove.topAnchor.constraint(equalTo: container.topAnchor),
            remove.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            remove.widthAnchor.constraint(equalToConstant: 22),
            remove.heightAnchor.constraint(equalToConstant: 22),
        ])
        return container
    }

    /// Re-pin the top of the stack (strip → reply banner → text field)
    /// so exactly one path is active for the current (strip, banner)
    /// visibility combination.
    private func updateTopChain() {
        textViewTopToPanelConstraint.isActive = false
        textViewTopToBannerConstraint.isActive = false
        textViewTopToStripConstraint.isActive = false
        replyBannerTopToPanelConstraint.isActive = false
        replyBannerTopToStripConstraint.isActive = false

        switch (hasPendingMedia, replyBannerShown) {
        case (true, true):
            replyBannerTopToStripConstraint.isActive = true
            textViewTopToBannerConstraint.isActive = true
        case (true, false):
            textViewTopToStripConstraint.isActive = true
        case (false, true):
            replyBannerTopToPanelConstraint.isActive = true
            textViewTopToBannerConstraint.isActive = true
        case (false, false):
            textViewTopToPanelConstraint.isActive = true
        }
    }

    private func layoutSubviewsLocal() {
        // Initial constant is replaced on the first
        // `refreshAfterTextChange` once the font / insets resolve.
        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        // Text-view top toggle. Default: pinned below the panel's top
        // inset. With a reply banner shown, pinned below the banner.
        textViewTopToPanelConstraint = textView.topAnchor.constraint(
            equalTo: topAnchor, constant: 8
        )
        textViewTopToBannerConstraint = textView.topAnchor.constraint(
            equalTo: replyBanner.bottomAnchor, constant: 8
        )
        textViewTopToStripConstraint = textView.topAnchor.constraint(
            equalTo: mediaStrip.bottomAnchor, constant: 8
        )
        // Reply-banner top toggle: below the panel top, or below the
        // media strip when it's staged above the banner.
        replyBannerTopToPanelConstraint = replyBanner.topAnchor.constraint(
            equalTo: topAnchor, constant: 8
        )
        replyBannerTopToStripConstraint = replyBanner.topAnchor.constraint(
            equalTo: mediaStrip.bottomAnchor, constant: 8
        )
        // Media strip — pinned across the panel top; height toggles
        // between 0 (hidden) and a thumbnail row.
        mediaStripHeightConstraint = mediaStrip.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            mediaStrip.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            mediaStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            mediaStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mediaStripHeightConstraint,

            // Reply banner — spans the width. Top is driven by the
            // toggle constraints; only leading/trailing are fixed here.
            replyBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            replyBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            replyBannerBar.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor),
            replyBannerBar.topAnchor.constraint(equalTo: replyBanner.topAnchor),
            replyBannerBar.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor),
            replyBannerBar.widthAnchor.constraint(equalToConstant: 3),

            replyCancelButton.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor),
            replyCancelButton.centerYAnchor.constraint(equalTo: replyBanner.centerYAnchor),
            replyCancelButton.widthAnchor.constraint(equalToConstant: 28),
            replyCancelButton.heightAnchor.constraint(equalToConstant: 28),

            replyBannerTitle.leadingAnchor.constraint(equalTo: replyBannerBar.trailingAnchor, constant: 8),
            replyBannerTitle.trailingAnchor.constraint(lessThanOrEqualTo: replyCancelButton.leadingAnchor, constant: -8),
            replyBannerTitle.topAnchor.constraint(equalTo: replyBanner.topAnchor),

            replyBannerSnippet.leadingAnchor.constraint(equalTo: replyBannerBar.trailingAnchor, constant: 8),
            replyBannerSnippet.trailingAnchor.constraint(lessThanOrEqualTo: replyCancelButton.leadingAnchor, constant: -8),
            replyBannerSnippet.topAnchor.constraint(equalTo: replyBannerTitle.bottomAnchor, constant: 1),
            replyBannerSnippet.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor),

            // Standalone circular attach button, gapped off the pill.
            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            attachButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 40),
            attachButton.heightAnchor.constraint(equalToConstant: 40),

            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textViewHeightConstraint,

            // Send + mic share the trailing slot — exactly one is visible
            // for a given composer state (see `refreshAfterTextChange`) —
            // and both float as a circle gapped off the pill.
            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 10),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // Bottom-aligned to the text view's bottom so a growing
            // text view keeps the send button on the last line.
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 40),
            sendButton.heightAnchor.constraint(equalToConstant: 40),

            micButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            micButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 40),
            micButton.heightAnchor.constraint(equalToConstant: 40),

            // Record-time overlay sits exactly over the text field.
            recordingOverlay.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            recordingOverlay.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            recordingOverlay.topAnchor.constraint(equalTo: textView.topAnchor),
            recordingOverlay.bottomAnchor.constraint(equalTo: textView.bottomAnchor),

            // Placeholder is positioned via static `textContainerInset`
            // values captured at constraint-creation time. The inset is
            // a constant today; if it ever becomes Dynamic-Type-driven
            // (or otherwise mutable), update these constraints' constants
            // in `refreshAfterTextChange` to keep the placeholder
            // aligned with the actual text cursor.
            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor,
                constant: textView.textContainerInset.left
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.topAnchor,
                constant: textView.textContainerInset.top
            ),
        ])

        // No banner by default — text view hangs off the panel top.
        textViewTopToPanelConstraint.isActive = true
    }

    // MARK: - Reply banner

    /// Show the "replying to" banner with the quoted sender + snippet,
    /// and re-pin the text view below it. Accent colors the bar + the
    /// title so the banner matches the bubble's quote.
    func showReplyBanner(name: String, snippet: String, accent: OnymAccent) {
        replyBannerTitle.text = "Replying to \(name)"
        replyBannerTitle.textColor = UIColor(accent.color)
        replyBannerBar.backgroundColor = UIColor(accent.color)
        replyBannerSnippet.text = snippet
        replyBanner.isHidden = false
        replyBannerShown = true
        updateTopChain()
    }

    /// Hide the reply banner and re-pin the text view to the panel top.
    func clearReplyBanner() {
        replyBanner.isHidden = true
        replyBannerShown = false
        replyBannerTitle.text = nil
        replyBannerSnippet.text = nil
        updateTopChain()
    }

    @objc private func tappedCancelReply() {
        onCancelReply?()
    }

    /// Raise the keyboard by focusing the composer — used by the host
    /// after arming a reply so the user can type immediately.
    func focusComposer() {
        textView.becomeFirstResponder()
    }

    // MARK: - Update

    /// Compute a new text-view height based on the current content,
    /// clamp to `[minTextViewHeight, maxHeight]`, and update the
    /// constraint + send button state + placeholder visibility.
    /// Caller-visible: `textViewDidChange(_:)` and the public
    /// `text` setter both invoke this.
    private func refreshAfterTextChange() {
        let body = textView.text ?? ""
        // Floor is "exactly one line of body text + insets"; cap is
        // the same formula at `maxLineCount`. Computed dynamically
        // so a Dynamic Type size change updates both.
        let floor = intrinsicHeight(forLines: 1)
        let cap = intrinsicHeight(forLines: Self.maxLineCount)

        // `sizeThatFits` returns the intrinsic content height for
        // the text view's current width. Pre-layout (zero width)
        // it returns garbage; fall back to the natural floor.
        //
        // TextKit 2 (iOS 18+ default) sometimes returns the pre-
        // mutation size when called immediately after a
        // programmatic `.text = ...` write. Force the text view
        // to flush its pending layout before measuring so the
        // value reflects the current body.
        textView.layoutIfNeeded()

        let measuredHeight: CGFloat = textView.bounds.width > 0
            ? textView.sizeThatFits(CGSize(
                width: textView.bounds.width,
                height: .greatestFiniteMagnitude
            )).height
            : floor

        let target = max(floor, min(cap, measuredHeight))
        if abs(textViewHeightConstraint.constant - target) > 0.5 {
            textViewHeightConstraint.constant = target
        }
        textView.isScrollEnabled = measuredHeight > cap

        // Send-button enable gate. Matches the trim in `tappedSend`
        // — whitespace-only input is treated as empty so the
        // disabled button is the canonical signal that nothing
        // would be sent. Placeholder visibility uses the raw
        // emptiness check so typing a space immediately hides the
        // overlay (the user *is* typing, even if the trimmed
        // content is still empty).
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Staged media alone is enough to send (no caption required).
        let hasContent = !trimmed.isEmpty || hasPendingMedia
        sendButton.isEnabled = hasContent
        // Right-side toggle: mic when the composer is empty, send otherwise.
        // While recording, the mic stays put (the finger is on it) and the
        // overlay covers the field regardless.
        if !isRecording {
            sendButton.isHidden = !hasContent
            micButton.isHidden = hasContent
        }
        placeholderLabel.isHidden = !body.isEmpty
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Once a real width is known, re-measure so the height
        // matches the actual content layout instead of the min-
        // height fallback used pre-layout.
        refreshAfterTextChange()
    }

    @objc private func tappedSend() {
        // Staged media takes priority: send the album (the caption field
        // isn't part of this iteration) and let the host clear the strip.
        if hasPendingMedia {
            onSendMediaTapped?()
            return
        }
        let body = (textView.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        onSendTapped?(body)
    }

    @objc private func tappedAttach() {
        onAttachTapped?()
    }

    /// Loopback-harness-only: a plain tap on the mic sends a canned voice
    /// message (the injected test encoder ignores the URL). No-op otherwise.
    @objc private func tappedMicDebug() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-loopback") else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        onSendVoiceTapped?(url)
        #endif
    }

    // MARK: - Voice recording

    @objc private func handleMicHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginRecording()
        case .changed:
            // Slide left past the threshold to arm cancel-on-release.
            let dx = gesture.location(in: micButton).x - micButton.bounds.midX
            let willCancel = dx < -cancelSlideThreshold
            if willCancel != recordingWillCancel {
                recordingWillCancel = willCancel
                recordingHintLabel.text = willCancel ? "release to cancel" : "‹ slide to cancel"
                recordingHintLabel.textColor = willCancel
                    ? UIColor.systemRed : UIColor(OnymTokens.text3)
            }
        case .ended:
            finishRecording(cancelled: recordingWillCancel)
        case .cancelled, .failed:
            finishRecording(cancelled: true)
        default:
            break
        }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingWillCancel = false
        Task { @MainActor in
            do {
                try await voiceRecorder.start()
                // The hold may have ended (or been cancelled) while the
                // permission prompt / session activation was in flight.
                guard isRecording else {
                    voiceRecorder.cancel()
                    return
                }
                showRecordingOverlay()
            } catch {
                // Permission denied or capture failed — silently reset to
                // the idle composer.
                isRecording = false
                hideRecordingOverlay()
            }
        }
    }

    private func finishRecording(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        stopRecordingTimer()
        hideRecordingOverlay()

        if cancelled {
            voiceRecorder.cancel()
            return
        }
        guard let result = voiceRecorder.stop() else { return }
        // Discard an accidental tap (too short to be a real message).
        guard result.duration >= ChatVoiceRecorder.minimumDuration else {
            try? FileManager.default.removeItem(at: result.url)
            return
        }
        onSendVoiceTapped?(result.url)
    }

    private func showRecordingOverlay() {
        recordingHintLabel.text = "‹ slide to cancel"
        recordingHintLabel.textColor = UIColor(OnymTokens.text3)
        recordingTimeLabel.text = "0:00"
        recordingOverlay.isHidden = false
        // Pulse the red dot while recording.
        recordingDot.layer.removeAllAnimations()
        UIView.animate(
            withDuration: 0.6, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]
        ) { [weak self] in
            self?.recordingDot.alpha = 0.2
        }
        startRecordingTimer()
    }

    private func hideRecordingOverlay() {
        recordingOverlay.isHidden = true
        recordingDot.layer.removeAllAnimations()
        recordingDot.alpha = 1
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let seconds = Int(self.voiceRecorder.duration)
            self.recordingTimeLabel.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

extension ChatInputPanelView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshAfterTextChange()
    }
}
