import UIKit
import OnymDesign
import OnymChatsCore

/// Centred, bubble-less row for a membership notice ("Alice joined").
///
/// Deliberately unlike `ChatBubbleCell`: no accent fill, no name header,
/// no status glyph, no tail. A notice is the app talking, not a person,
/// and giving it a bubble would put words in a member's mouth.
final class ChatSystemNoticeCell: UITableViewCell {
    static let reuseID = "ChatSystemNoticeCell"

    private let pill = UIView()
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = UIColor(OnymTokens.bg)

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor(OnymTokens.surface3)
        pill.layer.cornerRadius = 12
        pill.layer.cornerCurve = .continuous
        contentView.addSubview(pill)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = OnymType.uiFont(size: 13)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor(OnymTokens.text2)
        label.textAlignment = .center
        label.numberOfLines = 0
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            // Never let a long group name push the pill edge to edge.
            pill.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: 32
            ),
            pill.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -32
            ),

            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12)
        ])
    }

    /// Reads the event's own `localizedText` rather than re-deriving the
    /// sentence: the chat-list subtitle renders the same string, and a
    /// second copy here meant re-wording one silently diverged from the
    /// other.
    func configure(event: ChatSystemEvent) {
        label.text = event.localizedText
        // Identify the *label*, not the cell, and don't set
        // `isAccessibilityElement` on the cell — that collapses the
        // subtree and the text stops being exposed as a static text.
        // `ChatBubbleCell` leaves its labels exposed for the same
        // reason: the UI tests locate thread content by its text.
        label.accessibilityIdentifier = "chat.system_notice"
    }
}
