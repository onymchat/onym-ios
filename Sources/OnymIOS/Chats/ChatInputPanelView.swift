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
    private var textViewHeightConstraint: NSLayoutConstraint!

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
        backgroundColor = UIColor(OnymTokens.surface2)
        buildSubviews()
        buildReplyBanner()
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
        textView.backgroundColor = UIColor(OnymTokens.bg)
        textView.layer.cornerRadius = 18
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
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

        var sendConfig = UIButton.Configuration.plain()
        sendConfig.image = UIImage(
            systemName: "arrow.up.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        )
        sendConfig.contentInsets = .zero
        sendButton.configuration = sendConfig
        sendButton.tintColor = UIColor(OnymAccent.blue.color)
        sendButton.addTarget(self, action: #selector(tappedSend), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.accessibilityIdentifier = "chat.input.send"
        sendButton.accessibilityLabel = "Send"
        addSubview(sendButton)
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

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            // Reply banner — spans the width just under the panel top.
            // Only drives the text view's top when shown (toggle below).
            replyBanner.topAnchor.constraint(equalTo: topAnchor, constant: 8),
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

            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textViewHeightConstraint,

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 6),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // Bottom-aligned to the text view's bottom so a growing
            // text view keeps the send button on the last line.
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

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
        textViewTopToPanelConstraint.isActive = false
        textViewTopToBannerConstraint.isActive = true
    }

    /// Hide the reply banner and re-pin the text view to the panel top.
    func clearReplyBanner() {
        replyBanner.isHidden = true
        replyBannerTitle.text = nil
        replyBannerSnippet.text = nil
        textViewTopToBannerConstraint.isActive = false
        textViewTopToPanelConstraint.isActive = true
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
        sendButton.isEnabled = !trimmed.isEmpty
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
        let body = (textView.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        onSendTapped?(body)
    }
}

extension ChatInputPanelView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshAfterTextChange()
    }
}
