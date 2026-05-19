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

    // Direction-dependent constraints — only one of these pair is
    // active at a time.
    private var leadingAlignConstraint: NSLayoutConstraint!
    private var trailingAlignConstraint: NSLayoutConstraint!

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
            leadingAlignConstraint.isActive = false
            trailingAlignConstraint.isActive = true
        case .incoming:
            bubble.backgroundColor = UIColor(OnymTokens.surface2)
            bodyLabel.textColor = UIColor(OnymTokens.text)
            trailingAlignConstraint.isActive = false
            leadingAlignConstraint.isActive = true
        }
    }

    private func buildBubble() {
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 14
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .systemFont(ofSize: 15)
        bubble.addSubview(bodyLabel)
    }

    private func layoutBubble() {
        // Outer margins from the cell edges. The 56pt opposite-edge
        // inset is what gives the "addressed to the other side"
        // visual — a bubble pinned trailing still leaves room on
        // the left.
        let edgeInset: CGFloat = 12
        let opposite: CGFloat = 56

        leadingAlignConstraint = bubble.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: edgeInset
        )
        trailingAlignConstraint = bubble.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -edgeInset
        )

        let widthCap = bubble.widthAnchor.constraint(
            lessThanOrEqualTo: contentView.widthAnchor,
            multiplier: maxWidthFraction
        )

        NSLayoutConstraint.activate([
            // Vertical padding between rows.
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            // Always keep a gap on the opposite side from the active
            // alignment constraint so the bubble doesn't collide with
            // the opposite edge.
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: opposite
            ),
            bubble.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -opposite
            ),
            widthCap,

            // Body label fills the bubble with padding.
            bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bodyLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            bodyLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])

        // Default to leading (incoming). `configure(message:)` flips
        // before the cell is shown — but the default keeps the cell
        // layout-valid even if a configurer skips us.
        leadingAlignConstraint.isActive = true
    }
}
