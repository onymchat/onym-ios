import SwiftUI
import UIKit

/// One message bubble row. Two visual styles toggled by
/// `ChatMessage.direction`:
///
///   - `.outgoing` — accent-filled bubble pinned to the trailing edge.
///   - `.incoming` — surface-tinted bubble pinned to the leading edge.
///
/// Status indicator (PR 9): outgoing rows show a tiny glyph below
/// the bubble's trailing edge that reflects `ChatMessage.status`
/// (clock / check / red bang). Incoming rows hide the indicator —
/// the message arriving is the proof. Tapping a `.failed` bubble
/// invokes `onRetryRequested`, which the controller wires to
/// `SendMessageInteractor.retry`.
final class ChatBubbleCell: UITableViewCell {
    static let reuseID = "ChatBubbleCell"

    /// Max bubble width as a fraction of the cell's content width.
    /// Matches the usual messenger convention — long messages wrap
    /// but never reach the opposite edge.
    private let maxWidthFraction: CGFloat = 0.75

    private let bubble = UIView()
    private let bodyLabel = UILabel()
    private let statusImageView = UIImageView()

    /// Set by the diffable data source's cell provider on every
    /// dequeue. Fires when the user taps a `.failed` bubble —
    /// `configure(message:onRetry:)` only installs the tap target
    /// when the message is retry-eligible, so other states never
    /// fire this.
    private var onRetryRequested: (() -> Void)?
    private var retryTapRecognizer: UITapGestureRecognizer?

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

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.backgroundColor = UIColor(OnymTokens.bg)
        buildBubble()
        buildStatusIndicator()
        layoutBubble()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Swap colors + alignment + status indicator for the message.
    /// Caller (the diffable data source's cell provider) invokes
    /// this on every dequeue *and* every reconfigure — status flips
    /// on the same UUID land here too.
    func configure(message: ChatMessage, onRetry: (() -> Void)? = nil) {
        bodyLabel.text = message.body
        switch message.direction {
        case .outgoing:
            bubble.backgroundColor = UIColor(OnymAccent.blue.color)
            bodyLabel.textColor = UIColor(OnymTokens.onAccent)
            NSLayoutConstraint.deactivate(incomingConstraints)
            NSLayoutConstraint.activate(outgoingConstraints)
            bubbleBottomConstraint.isActive = false
            statusBottomConstraint.isActive = true
            applyStatus(message.status)
        case .incoming:
            bubble.backgroundColor = UIColor(OnymTokens.surface2)
            bodyLabel.textColor = UIColor(OnymTokens.text)
            NSLayoutConstraint.deactivate(outgoingConstraints)
            NSLayoutConstraint.activate(incomingConstraints)
            statusBottomConstraint.isActive = false
            bubbleBottomConstraint.isActive = true
            statusImageView.isHidden = true
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

    private func applyStatus(_ status: MessageStatus) {
        statusImageView.isHidden = false
        switch status {
        case .pending:
            statusImageView.image = UIImage(systemName: "clock")
            statusImageView.tintColor = UIColor(OnymTokens.text3)
            statusImageView.accessibilityLabel = "Sending"
        case .sent:
            statusImageView.image = UIImage(systemName: "checkmark")
            statusImageView.tintColor = UIColor(OnymTokens.text3)
            statusImageView.accessibilityLabel = "Sent"
        case .failed:
            statusImageView.image = UIImage(systemName: "exclamationmark.circle.fill")
            statusImageView.tintColor = UIColor(OnymTokens.red)
            statusImageView.accessibilityLabel = "Failed — tap to retry"
        case .received:
            // Outgoing rows never carry .received; hide as a
            // defensive default if a bad row somehow lands here.
            statusImageView.isHidden = true
        }
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
        bubble.addSubview(bodyLabel)
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
        contentView.addSubview(statusImageView)
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

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor,
                multiplier: maxWidthFraction
            ),
            bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bodyLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            bodyLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),

            // Status indicator sits in the gap below the bubble,
            // trailing-aligned. Always positioned relative to the
            // bubble; only the cell-bottom anchor differs between
            // directions (see `bubbleBottomConstraint` vs
            // `statusBottomConstraint`).
            statusImageView.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
            statusImageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalToConstant: 14),
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
        // Default to leading (incoming) — `configure(message:)`
        // overrides before the cell is shown, but the default keeps
        // the cell layout-valid even if a configurer skips us.
        NSLayoutConstraint.activate(incomingConstraints)
        bubbleBottomConstraint.isActive = true
    }
}
