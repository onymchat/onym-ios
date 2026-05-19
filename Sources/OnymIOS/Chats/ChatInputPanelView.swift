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

    var text: String {
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

    private func layoutSubviewsLocal() {
        // Initial constant is replaced on the first
        // `refreshAfterTextChange` once the font / insets resolve.
        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textViewHeightConstraint,

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 6),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // Bottom-aligned to the text view's bottom so a growing
            // text view keeps the send button on the last line.
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor,
                constant: textView.textContainerInset.left
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.topAnchor,
                constant: textView.textContainerInset.top
            ),
        ])
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
        sendButton.isEnabled = !body.isEmpty
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
