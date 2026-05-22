import SwiftUI
import UIKit

/// Top-level chat-screen controller. UIKit-first per the design call
/// (#150 plan): nav bar, message list, and input panel are all
/// UIKit. SwiftUI hosts this controller via `ChatThreadView`.
///
/// PR 5 scope — skeleton only:
/// - Custom title bar at the top (back chevron, group name, info
///   button). SwiftUI's nav bar is hidden by the wrapper.
/// - Empty `UITableView` placeholder where messages will render in
///   PR 6.
/// - Empty `UIView` placeholder where the input panel + send button
///   will land in PR 6 / PR 7.
///
/// No keyboard handling, no message rendering, no send — those
/// arrive in later PRs. Tapping the info button forwards to the
/// SwiftUI parent, which pushes `ChatMembersView` via
/// `navigationDestination(isPresented:)`.
final class ChatThreadViewController: UIViewController {
    /// Invoked when the user taps the back chevron. The SwiftUI
    /// wrapper points this at `Environment(\.dismiss)` so the
    /// existing `NavigationStack` pops correctly.
    var onBack: (() -> Void)?

    /// Invoked when the user taps the info button. The SwiftUI
    /// wrapper toggles a `@State` flag that triggers the members-
    /// view push.
    var onShowMembers: (() -> Void)?

    /// Invoked when the user taps the input panel's Send button
    /// with non-whitespace content. The SwiftUI wrapper points
    /// this at `SendMessageInteractor.send(groupID:body:)` —
    /// fire-and-forget; the interactor handles optimistic insert,
    /// fan-out, and status flip on its own. Receives the body
    /// already trimmed of leading/trailing whitespace by the
    /// input panel.
    var onSendTapped: ((String) -> Void)?

    /// Invoked when the user taps a `.failed` outgoing bubble.
    /// The SwiftUI wrapper points this at
    /// `SendMessageInteractor.retry(groupID:messageID:)` — same
    /// fire-and-forget contract as `onSendTapped`. Only `.failed`
    /// rows have the tap target installed by `ChatBubbleCell`, so
    /// this never fires for other statuses.
    var onRetryRequested: ((UUID) -> Void)?

    private let titleLabel = UILabel()
    private let memberCountLabel = UILabel()
    private let titleStack = UIStackView()
    private let backButton = UIButton(type: .system)
    private let infoButton = UIButton(type: .system)
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let tableView = UITableView()
    private let emptyStateLabel = UILabel()
    private let inputPanel = ChatInputPanelView()

    // Diffable data source state. Keyed by message UUID — stable
    // identity across re-renders, no array-index churn.
    private enum Section: Hashable { case main }
    private var dataSource: UITableViewDiffableDataSource<Section, UUID>!
    /// Lookup table the cell-provider reads from. Keys mirror the
    /// diffable snapshot's items so a dequeue can always resolve.
    private var messagesByID: [UUID: ChatMessage] = [:]
    /// Set after the first `update(messages:)` so the initial load
    /// applies non-animated + always scrolls to the bottom, while
    /// subsequent updates animate and only auto-scroll when the
    /// user is already near the bottom.
    private var hasAppliedFirstSnapshot = false

    /// "Within this many points of the content bottom" counts as
    /// "near bottom" for the auto-scroll heuristic. Exposed for
    /// tests; production-only callers should treat as a constant.
    static let nearBottomThreshold: CGFloat = 100

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(OnymTokens.bg)
        buildTopBar()
        buildTableView()
        buildInputPanel()
        layout()
        configureDataSource()
    }

    /// Push a new group-name + member-count into the title bar.
    /// Called by the SwiftUI wrapper on every render — keeps the
    /// bar in sync as the group renames or new joiners land without
    /// re-creating the controller.
    ///
    /// `memberCount` of zero or one hides the subtitle (singleton
    /// groups don't need a member count; nothing-known groups
    /// would just show "0 members" awkwardly).
    func update(groupName: String, memberCount: Int) {
        titleLabel.text = groupName.isEmpty ? "Chat" : groupName
        if memberCount > 1 {
            memberCountLabel.text = "\(memberCount) members"
            memberCountLabel.isHidden = false
        } else {
            memberCountLabel.text = nil
            memberCountLabel.isHidden = true
        }
    }

    /// Push a new message list into the table. Called by the SwiftUI
    /// wrapper on every render with the latest snapshot from
    /// `MessageRepository.snapshots(groupID:)`. The diffable data
    /// source figures out the inserts/deletes/moves; rows that
    /// didn't change don't re-layout.
    ///
    /// Behavior:
    ///   - First apply (cold open): non-animated, always scroll to
    ///     the bottom so the user lands on the latest message.
    ///   - Subsequent applies: animated; only scroll to bottom if
    ///     the user was already near it (otherwise we'd hijack
    ///     mid-scroll reading of older messages).
    ///
    /// Defensively sorts by `sentAt` ascending. The repository's
    /// contract is already to return sorted snapshots
    /// (`SwiftDataMessageStoreTests.test_list_sortsBySentAtAscending`),
    /// but a future caller / test stub might violate that without
    /// the sort here protecting the table's row order.
    ///
    /// Status flips on the same UUID land via
    /// `snapshot.reconfigureItems(changedIDs)` — the row stays at
    /// the same index but the cell provider re-runs against the
    /// updated `messagesByID` entry, so a `.pending` → `.sent`
    /// transition swaps the glyph without animating the bubble.
    func update(messages: [ChatMessage]) {
        let isFirstApply = !hasAppliedFirstSnapshot
        let wasNearBottom = isNearBottom

        let sorted = messages.sorted { $0.sentAt < $1.sentAt }
        // Detect status/body changes on already-known rows so
        // `reconfigureItems` can repaint their cells without
        // deleting + reinserting (which would animate the bubble).
        let changedIDs: [UUID] = sorted.compactMap { msg in
            guard let prior = messagesByID[msg.id], prior != msg else { return nil }
            return msg.id
        }
        messagesByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })

        // Empty state: visible iff the message list is empty. Lives
        // behind the table view (added as a sibling); toggling
        // `isHidden` is cheap and survives keyboard show/hide.
        emptyStateLabel.isHidden = !sorted.isEmpty

        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(sorted.map(\.id))
        if !changedIDs.isEmpty {
            snapshot.reconfigureItems(changedIDs)
        }
        // First apply is non-animated to avoid an initial-load
        // "fly-in" of every existing message.
        dataSource.apply(snapshot, animatingDifferences: !isFirstApply) { [weak self] in
            guard let self else { return }
            if isFirstApply {
                self.scrollToBottom(animated: false)
                self.hasAppliedFirstSnapshot = true
            } else if wasNearBottom {
                self.scrollToBottom(animated: true)
            }
        }
    }

    /// True when the user is within `nearBottomThreshold` points of
    /// the content bottom. Used to decide whether a fresh message
    /// should pull the scroll along or leave the user where they
    /// are. Exposed for tests; production-only callers should treat
    /// as private.
    var isNearBottom: Bool {
        let contentHeight = tableView.contentSize.height
        let visibleHeight = tableView.bounds.height
        let offsetY = tableView.contentOffset.y
        // When the content is shorter than the viewport (empty / few
        // messages), we're always "at the bottom" — auto-scroll has
        // nothing to do.
        guard contentHeight > visibleHeight else { return true }
        let maxOffset = contentHeight - visibleHeight
        return maxOffset - offsetY < Self.nearBottomThreshold
    }

    /// Scroll the table so the last row is visible.
    func scrollToBottom(animated: Bool) {
        let snapshot = dataSource.snapshot()
        guard let lastSection = snapshot.sectionIdentifiers.last else { return }
        let itemCount = snapshot.numberOfItems(inSection: lastSection)
        guard itemCount > 0 else { return }
        let lastIndex = IndexPath(row: itemCount - 1, section: 0)
        tableView.scrollToRow(at: lastIndex, at: .bottom, animated: animated)
    }

    // MARK: - Top bar

    private func buildTopBar() {
        topBar.backgroundColor = UIColor(OnymTokens.bg)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // Back chevron. SF Symbol chevron.left at semantic accent so
        // it reads as a tap target in both light and dark.
        var backConfig = UIButton.Configuration.plain()
        backConfig.image = UIImage(systemName: "chevron.left",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        backConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        backButton.configuration = backConfig
        backButton.tintColor = UIColor(OnymTokens.text2)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.addTarget(self, action: #selector(tappedBack), for: .touchUpInside)
        backButton.accessibilityLabel = "Back"
        backButton.accessibilityIdentifier = "chat.back"
        topBar.addSubview(backButton)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = UIColor(OnymTokens.text)
        titleLabel.textAlignment = .center
        titleLabel.text = "Chat"
        titleLabel.accessibilityIdentifier = "chat.title"

        memberCountLabel.font = .systemFont(ofSize: 11, weight: .regular)
        memberCountLabel.textColor = UIColor(OnymTokens.text3)
        memberCountLabel.textAlignment = .center
        memberCountLabel.isHidden = true
        memberCountLabel.accessibilityIdentifier = "chat.title.member_count"

        titleStack.axis = .vertical
        titleStack.alignment = .center
        titleStack.spacing = 1
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(memberCountLabel)
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleStack)

        var infoConfig = UIButton.Configuration.plain()
        infoConfig.image = UIImage(systemName: "info.circle",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        infoConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        infoButton.configuration = infoConfig
        infoButton.tintColor = UIColor(OnymTokens.text2)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.addTarget(self, action: #selector(tappedInfo), for: .touchUpInside)
        infoButton.accessibilityLabel = "Group info"
        infoButton.accessibilityIdentifier = "chat.info"
        topBar.addSubview(infoButton)

        topBarSeparator.backgroundColor = UIColor(OnymTokens.hairline)
        topBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarSeparator)
    }

    // MARK: - Table view (message list)

    private func buildTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = UIColor(OnymTokens.bg)
        tableView.separatorStyle = .none
        // Self-sizing rows — bubble height grows with body text.
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.register(ChatBubbleCell.self, forCellReuseIdentifier: ChatBubbleCell.reuseID)
        tableView.keyboardDismissMode = .interactive
        view.addSubview(tableView)

        // Empty state — shown when the message list is empty, hidden
        // as soon as the first message arrives. Positioned centered
        // between the top bar and the input panel so it doesn't get
        // covered when the keyboard rises.
        emptyStateLabel.text = "No messages yet. Say hi."
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.font = .preferredFont(forTextStyle: .body)
        emptyStateLabel.adjustsFontForContentSizeCategory = true
        emptyStateLabel.textColor = UIColor(OnymTokens.text3)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
        emptyStateLabel.accessibilityIdentifier = "chat.empty_state"
        view.addSubview(emptyStateLabel)
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Section, UUID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ChatBubbleCell.reuseID,
                for: indexPath
            )
            if let bubble = cell as? ChatBubbleCell,
               let message = self?.messagesByID[id] {
                let retryHandler: (() -> Void)? = {
                    guard message.direction == .outgoing,
                          message.status == .failed else { return nil }
                    return { [weak self] in self?.onRetryRequested?(id) }
                }()
                bubble.configure(message: message, onRetry: retryHandler)
            }
            return cell
        }
        // No animations on the initial empty section commit; only
        // mutations after `update(messages:)` need animation.
        var initial = NSDiffableDataSourceSnapshot<Section, UUID>()
        initial.appendSections([.main])
        dataSource.apply(initial, animatingDifferences: false)
    }

    // MARK: - Input panel

    private func buildInputPanel() {
        inputPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputPanel)
        // Forward to the host-supplied dispatcher first (so the
        // closure sees the typed body), then clear the field. The
        // dispatcher is fire-and-forget — `SendMessageInteractor`
        // does the optimistic insert before the await, so the
        // user's message appears in the table via the snapshot
        // stream long before the network round-trip resolves;
        // clearing the field straight after the tap keeps the
        // composer feeling responsive.
        inputPanel.onSendTapped = { [weak self] body in
            self?.onSendTapped?(body)
            self?.inputPanel.text = ""
        }
    }

    // MARK: - Layout

    private func layout() {
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Top bar — pinned to the safe area, fixed 44pt height
            // (matches iOS nav bar default).
            topBar.topAnchor.constraint(equalTo: safeArea.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 36),
            backButton.heightAnchor.constraint(equalToConstant: 36),

            infoButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            infoButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 36),
            infoButton.heightAnchor.constraint(equalToConstant: 36),

            titleStack.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -8),

            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            // Table view — fills the space between the top bar and
            // the input panel.
            tableView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputPanel.topAnchor),

            // Empty state — centered in the same region the table
            // view occupies. Sits behind the table; toggled on
            // when the message list is empty.
            emptyStateLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: tableView.leadingAnchor, constant: 32
            ),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: tableView.trailingAnchor, constant: -32
            ),

            // Input panel — bottom tracks the keyboard. With no
            // keyboard up, `keyboardLayoutGuide.topAnchor` equals
            // the safe-area bottom; when the keyboard rises the
            // guide tracks its top edge and the panel slides
            // along automatically. No manual frame math or
            // `keyboardWillShow` notifications required.
            //
            // Height is intrinsic — driven by the text view's
            // height constraint inside the panel — so a multi-
            // line composition pushes the message list up.
            inputPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputPanel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func tappedBack() { onBack?() }
    @objc private func tappedInfo() { onShowMembers?() }
}
