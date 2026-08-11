import UIKit
import OnymDesign
import OnymGroup

/// What the thread needs to render one pending join request. Built by
/// `ChatThreadViewController` from `JoinRequestApprover.PendingRequest`
/// plus the flow's in-flight/error state, so the cell stays dumb —
/// matching how `ChatSenderDisplay` / `ChatReplyQuote` feed
/// `ChatBubbleCell`.
struct ChatJoinRequestDisplay: Equatable {
    /// `PendingRequest.id` — the key Accept / Decline are dispatched on.
    let requestID: String
    let alias: String
    /// Short hex of the joiner's inbox pubkey. Shown so the founder can
    /// confirm out-of-band who is actually asking: the alias is
    /// self-asserted by the joiner and nothing stops them typing someone
    /// else's name.
    let fingerprint: String
    /// Approve is blocked when the request names a group this device
    /// doesn't have — approving would fail anyway. Decline stays live so
    /// the row can still be cleared.
    let canAccept: Bool
    /// A call is in flight: spinner on, both buttons disabled.
    let isInFlight: Bool
    /// Last failure for this request, if any.
    let errorText: String?
}

/// Founder-only, in-thread prompt: "Alice wants to join" with Accept /
/// Decline.
///
/// This replaces the separate "Join requests" screen. The request is
/// already cryptographically founder-only — it arrives sealed to an
/// intro key only the inviting device holds — so nothing here is hidden
/// from anyone who could otherwise see it; the row simply never has
/// content to render on a non-founder's device.
final class ChatJoinRequestCell: UITableViewCell {
    static let reuseID = "ChatJoinRequestCell"

    /// Fired with the `PendingRequest.id`.
    var onAccept: ((String) -> Void)?
    var onDecline: ((String) -> Void)?

    private var requestID: String?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let fingerprintLabel = UILabel()
    private let errorLabel = UILabel()
    private let hintLabel = UILabel()
    private let declineButton = UIButton(type: .system)
    private let acceptButton = UIButton(type: .system)
    private let buttonRow = UIStackView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = UIColor(OnymTokens.bg)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(OnymTokens.surface2)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(OnymTokens.hairline).cgColor
        contentView.addSubview(card)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = UIColor(OnymTokens.text)
        titleLabel.numberOfLines = 0

        fingerprintLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        fingerprintLabel.adjustsFontForContentSizeCategory = true
        fingerprintLabel.textColor = UIColor(OnymTokens.text3)
        fingerprintLabel.numberOfLines = 1

        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = UIColor(OnymTokens.red)
        errorLabel.numberOfLines = 0

        // The on-chain admit is a PLONK proof plus a relayer round-trip
        // plus a Stellar confirmation — several seconds of apparent
        // nothing. Say so rather than letting it read as a hung tap.
        hintLabel.font = .preferredFont(forTextStyle: .caption2)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = UIColor(OnymTokens.text2)
        hintLabel.numberOfLines = 0
        hintLabel.text = String(
            localized: "Generating proof and updating the on-chain commitment. This usually takes a few seconds."
        )

        declineButton.configuration = Self.buttonConfiguration(
            title: String(localized: "Decline"),
            filled: false
        )
        acceptButton.configuration = Self.buttonConfiguration(
            title: String(localized: "Accept"),
            filled: true
        )
        declineButton.addTarget(self, action: #selector(tappedDecline), for: .touchUpInside)
        acceptButton.addTarget(self, action: #selector(tappedAccept), for: .touchUpInside)

        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(declineButton)
        buttonRow.addArrangedSubview(acceptButton)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(fingerprintLabel)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(errorLabel)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            declineButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    /// `UIButton.Configuration` rather than the older
    /// `setTitle`/`contentEdgeInsets` pair: it carries the activity
    /// indicator natively, so the in-flight spinner needs no manual
    /// layout or inset juggling to keep off the title.
    private static func buttonConfiguration(
        title: String,
        filled: Bool
    ) -> UIButton.Configuration {
        var config: UIButton.Configuration = filled ? .filled() : .gray()
        config.title = title
        config.cornerStyle = .medium
        config.baseBackgroundColor = filled
            ? UIColor(OnymAccent.blue.color)
            : UIColor(OnymTokens.surface3)
        config.baseForegroundColor = filled
            ? UIColor(OnymTokens.onAccent)
            : UIColor(OnymTokens.text)
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .preferredFont(forTextStyle: .subheadline)
            return out
        }
        return config
    }

    func configure(_ display: ChatJoinRequestDisplay) {
        requestID = display.requestID

        titleLabel.text = String(localized: "\(display.alias) wants to join")
        fingerprintLabel.text = String(localized: "inbox \(display.fingerprint)")

        var accept = Self.buttonConfiguration(
            title: display.isInFlight
                ? String(localized: "Anchoring on chain…")
                : String(localized: "Accept"),
            filled: true
        )
        accept.showsActivityIndicator = display.isInFlight
        acceptButton.configuration = accept
        acceptButton.isEnabled = display.canAccept && !display.isInFlight

        // Decline stays live when the group is merely unknown to this
        // device — the founder still needs a way to clear the row.
        declineButton.isEnabled = !display.isInFlight

        // A disabled Accept with no explanation is the worst of both.
        // The state should be unreachable (the row only renders inside a
        // group's own thread), but if it ever is reached, say why and
        // point at the way out — the copy the deleted modal carried.
        // In-flight wins. Both states at once should be unreachable —
        // an un-acceptable request can't be in flight — but if it
        // happens, the spinner is what the founder is looking at, and
        // explaining a button they just pressed as unavailable would be
        // the wrong caption for it.
        if display.isInFlight {
            hintLabel.text = String(
                localized: "Generating proof and updating the on-chain commitment. This usually takes a few seconds."
            )
        } else {
            hintLabel.text = String(
                localized: "This request is for a group that isn’t on this device. Decline to clear it."
            )
        }
        hintLabel.isHidden = display.canAccept && !display.isInFlight

        errorLabel.text = display.errorText
        errorLabel.isHidden = display.errorText == nil

        accessibilityIdentifier = "chat.join_request.\(display.requestID)"
        acceptButton.accessibilityIdentifier = "chat.join_request.accept.\(display.requestID)"
        declineButton.accessibilityIdentifier = "chat.join_request.decline.\(display.requestID)"
    }

    @objc private func tappedAccept() {
        guard let requestID else { return }
        onAccept?(requestID)
    }

    @objc private func tappedDecline() {
        guard let requestID else { return }
        onDecline?(requestID)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        requestID = nil
        onAccept = nil
        onDecline = nil
    }
}
