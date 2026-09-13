import SwiftUI
import UIKit

/// Hosts a treasury proposal card in the chat thread.
///
/// The card itself is SwiftUI and lives in `OnymTreasuryUI`; it arrives
/// here already built, as an opaque `AnyView` from a factory — the same
/// arrangement the moderation report sheet uses, and for the same
/// reason: this package stays free of any dependency on the treasury
/// UI.
///
/// It is a `UIHostingConfiguration` rather than a hand-built UIKit cell
/// like `ChatJoinRequestCell`, because the card is rendered in two
/// places — here and on the treasury screen — and two implementations
/// of one card is exactly how a person ends up approving a transaction
/// whose description differs from the one they read.
///
/// No `configure(_:)` taking content, and no reconfigure plumbing: the
/// hosted view observes the treasury flow directly, so a signature
/// arriving from another member updates this row without the table
/// being told anything.
final class ChatTreasuryProposalCell: UITableViewCell {
    static let reuseID = "ChatTreasuryProposalCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(card: AnyView) {
        // Zero margins on purpose: the hosted view supplies its own
        // insets *and* collapses to nothing when there is nothing
        // waiting on signatures. A configuration with margins would
        // leave a visible gap in the thread on every quiet day.
        contentConfiguration = UIHostingConfiguration { card }
            .margins(.all, 0)
            .background(Color.clear)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
    }
}
