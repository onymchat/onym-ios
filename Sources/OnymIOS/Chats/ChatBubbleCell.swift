import SwiftUI
import UIKit

/// One message bubble row. Two visual styles toggled by
/// `ChatMessage.direction`:
///
///   - `.outgoing` — accent-filled bubble pinned to the trailing edge.
///   - `.incoming` — surface-tinted bubble pinned to the leading edge.
///
/// Layout is a single `UILabel` inside a `UIView` bubble container.
/// The bubble's leading/trailing edge is swapped via two stored
/// constraints; the `lessThanOrEqualTo` width cap keeps long
/// messages from filling the full row.
///
/// PR 6 scope: no avatars, no timestamps, no status glyphs, no
/// emoji rendering. Status indicator lands in PR 8.
final class ChatBubbleCell: UITableViewCell {
    static let reuseID = "ChatBubbleCell"

    /// Max bubble width as a fraction of the cell's content width.
    /// Matches the usual messenger convention — long messages wrap
    /// but never reach the opposite edge.
    private let maxWidthFraction: CGFloat = 0.75

    private let bubble = UIView()
    private let bodyLabel = UILabel()

    // Direction-dependent constraints — only one pair is active at a
    // time. Each pair contains the alignment pin (`==` to the pinned
    // edge) and the opposite-edge breathing-room gap on the *other*
    // side. Pairing this way prevents the obvious-but-wrong layout:
    // pinning `leading == +12` while also asserting `leading >= +56`
    // (the original PR 6 shape) breaks every cell with a constraint
    // log.
    private var outgoingConstraints: [NSLayoutConstraint] = []
    private var incomingConstraints: [NSLayoutConstraint] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.backgroundColor = UIColor(OnymTokens.bg)
        buildBubble()
        layoutBubble()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Swap colors + alignment for the message's direction. Caller
    /// (the diffable data source's cell provider) invokes this on
    /// every dequeue.
    func configure(message: ChatMessage) {
        bodyLabel.text = message.body
        switch message.direction {
        case .outgoing:
            bubble.backgroundColor = UIColor(OnymAccent.blue.color)
            bodyLabel.textColor = UIColor(OnymTokens.onAccent)
            NSLayoutConstraint.deactivate(incomingConstraints)
            NSLayoutConstraint.activate(outgoingConstraints)
        case .incoming:
            bubble.backgroundColor = UIColor(OnymTokens.surface2)
            bodyLabel.textColor = UIColor(OnymTokens.text)
            NSLayoutConstraint.deactivate(outgoingConstraints)
            NSLayoutConstraint.activate(incomingConstraints)
        }
    }

    private func buildBubble() {
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 14
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        // Dynamic Type — the chat body should scale with the user's
        // preferred text size. Full a11y polish pass happens later
        // (PR 9+), but using `preferredFont(forTextStyle:)` here
        // costs nothing now and avoids a fixed-size regression.
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bubble.addSubview(bodyLabel)
    }

    private func layoutBubble() {
        let edgeInset: CGFloat = 12
        // Opposite-edge gap: the side the bubble does NOT pin to
        // still leaves this much breathing room from the cell edge.
        // Gives the "addressed to one side" visual without the
        // bubble ever filling the row, even for super-short content
        // that the width cap doesn't bind on.
        let oppositeGap: CGFloat = 56

        // Always-active constraints (don't depend on direction).
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor,
                multiplier: maxWidthFraction
            ),
            bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bodyLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            bodyLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
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
    }
}
