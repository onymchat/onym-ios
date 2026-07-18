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
    /// this at `SendMessageInteractor.send(groupID:body:replyToMessageID:)`
    /// — fire-and-forget; the interactor handles optimistic insert,
    /// fan-out, and status flip on its own. Receives the body
    /// already trimmed of leading/trailing whitespace by the input
    /// panel, plus the armed reply target (nil for a normal message).
    var onSendTapped: ((String, UUID?) -> Void)?

    /// Invoked when the user taps a `.failed` outgoing bubble.
    /// The SwiftUI wrapper points this at
    /// `SendMessageInteractor.retry(groupID:messageID:)` — same
    /// fire-and-forget contract as `onSendTapped`. Only `.failed`
    /// rows have the tap target installed by `ChatBubbleCell`, so
    /// this never fires for other statuses.
    var onRetryRequested: ((UUID) -> Void)?

    /// Loader used by bubbles to fetch + decrypt image attachments.
    var imageLoader: ChatImageLoader?
    /// Fired when a message's image is tapped (host presents full-screen).
    var onImageTapped: ((ChatMessage) -> Void)?
    /// Fired when the composer's attach button is tapped (host presents
    /// the photo picker).
    var onAttachTapped: (() -> Void)?

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

    /// Full-width swipe-to-go-back pan. Borrows the system pop
    /// transition's target/action so a horizontal swipe anywhere on the
    /// screen drives the same interactive pop as the edge gesture.
    private var fullWidthPanGesture: UIPanGestureRecognizer?

    // Diffable data source state. Keyed by message UUID — stable
    // identity across re-renders, no array-index churn.
    private enum Section: Hashable { case main }
    private var dataSource: UITableViewDiffableDataSource<Section, UUID>!
    /// Lookup table the cell-provider reads from. Keys mirror the
    /// diffable snapshot's items so a dequeue can always resolve.
    private var messagesByID: [UUID: ChatMessage] = [:]
    /// Same messages as `messagesByID`, kept in display order so the
    /// run-grouping pass (name header at the start of each consecutive
    /// same-sender run) can look at neighbours.
    private var orderedMessages: [ChatMessage] = []
    /// The parent group's member profiles, keyed by BLS pubkey hex —
    /// the source for resolving a sender's alias. Pushed by the SwiftUI
    /// wrapper via `update(memberProfiles:)`; updated live as joiners
    /// land or aliases change.
    private var memberProfiles: [String: MemberProfile] = [:]
    /// Per-message resolved sender presentation (name + accent + whether
    /// to show the header), rebuilt whenever messages or member profiles
    /// change. The cell-provider reads this so the cell stays a dumb
    /// renderer.
    private var senderDisplays: [UUID: ChatSenderDisplay] = [:]
    /// Set after the first `update(messages:)` so the initial load
    /// applies non-animated + always scrolls to the bottom, while
    /// subsequent updates animate and only auto-scroll when the
    /// user is already near the bottom.
    private var hasAppliedFirstSnapshot = false

    /// The message the composer is currently replying to, if any. Set
    /// by a swipe-to-reply on a bubble, cleared on cancel or after a
    /// send. Threaded into `onSendTapped` so the sent message carries
    /// the reply reference.
    private var replyingTo: UUID?

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

        // The input panel rides the keyboard up via the
        // `keyboardLayoutGuide` constraint, which shrinks the message
        // list from the bottom — leaving the latest messages under the
        // keyboard. Rather than scroll *after* the keyboard settles
        // (which reads as a late jump), shift the content up by the same
        // amount the keyboard moves, animated on the keyboard's own
        // duration + curve, so the bottom message stays glued to the
        // input area throughout the transition.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    // The SwiftUI wrapper hides the nav bar (the controller paints its
    // own), which makes UIKit disable the edge-swipe interactive pop
    // gesture. Rather than just re-arm the narrow edge gesture, install
    // a full-width pan that drives the *same* interactive pop transition
    // — so a swipe anywhere on the chat screen goes back to the list.
    //
    // The trick: lift the hidden target/action off the system
    // `interactivePopGestureRecognizer` (it points at UIKit's private
    // navigation-transition driver) and attach it to our own pan. The
    // edge recognizer stays delegate-gated so the two don't fight.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installFullWidthPopGesture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }

    private func installFullWidthPopGesture() {
        guard let popGesture = navigationController?.interactivePopGestureRecognizer,
              let targets = popGesture.value(forKey: "targets") as? [AnyObject],
              fullWidthPanGesture == nil else {
            // Already installed (or nothing to borrow) — just keep the
            // edge gesture delegate-gated so it begins from the root-
            // guard check below.
            navigationController?.interactivePopGestureRecognizer?.delegate = self
            return
        }

        let pan = UIPanGestureRecognizer()
        pan.setValue(targets, forKey: "targets")
        pan.delegate = self
        view.addGestureRecognizer(pan)
        fullWidthPanGesture = pan

        // Keep the system edge gesture alive too (delegate-gated) so
        // the standard edge swipe still works alongside the full-width
        // one.
        popGesture.delegate = self
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
    /// Push the parent group's member profiles in. Used to resolve
    /// sender aliases (and, via the BLS keys, per-sender accent colors)
    /// for the name headers. Called by the SwiftUI wrapper on every
    /// render — a no-op when unchanged. When the profiles do change
    /// (joiner admitted, alias edited), the already-rendered rows are
    /// reconfigured so their headers pick up the new name without a
    /// fresh message arriving.
    ///
    /// Must be called before `update(messages:)` on first render so the
    /// initial sender-display build sees the profiles; the wrapper
    /// orders the two calls that way.
    func update(memberProfiles: [String: MemberProfile]) {
        guard memberProfiles != self.memberProfiles else { return }
        self.memberProfiles = memberProfiles
        rebuildSenderDisplays()

        // Repaint already-committed rows against the refreshed
        // names/colors. Reconfigure only the items actually in the
        // current snapshot (so this is safe before the first
        // message-snapshot commits — nothing to reconfigure yet) and
        // never reload, so nothing animates.
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

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
        orderedMessages = sorted
        rebuildSenderDisplays()

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
                // Cold open: land at the bottom with no visible scroll.
                // Only the first *non-empty* snapshot counts as the cold
                // open — the SwiftUI bridge's initial render is empty, and
                // treating that as "first" would make the real messages a
                // normal (animated) update that scrolls up from the top.
                guard !sorted.isEmpty else { return }
                self.jumpToBottomForColdOpen()
                self.hasAppliedFirstSnapshot = true
            } else if wasNearBottom {
                self.scrollToBottom(animated: true)
            }
        }
    }

    /// Position the cold open directly at the latest message, without
    /// the user ever seeing the top→bottom scroll. The table is hidden
    /// (alpha 0) until here; we lay out, scroll to the bottom, and — on
    /// the next runloop, after the table has corrected its estimated row
    /// heights to actual — scroll once more and reveal, so any settle is
    /// masked.
    private func jumpToBottomForColdOpen() {
        tableView.layoutIfNeeded()
        scrollToBottom(animated: false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollToBottom(animated: false)
            if self.tableView.alpha == 0 { self.tableView.alpha = 1 }
        }
    }

    /// Recompute the per-message sender presentation from the current
    /// `orderedMessages` + `memberProfiles`. A name header shows only at
    /// the *start* of a run of consecutive same-sender messages, only
    /// for incoming messages (own messages are obvious from alignment +
    /// color), and never in 1-on-1 groups (a single other person doesn't
    /// need to be named on every run). Color is hashed from the BLS
    /// pubkey, so it's stable per-person and independent of the alias.
    private func rebuildSenderDisplays() {
        var displays: [UUID: ChatSenderDisplay] = [:]
        var previousSender: String?
        for message in orderedMessages {
            let isRunStart = message.senderBlsPubkeyHex != previousSender
            let showHeader = isRunStart
                && message.direction == .incoming
                && message.groupType != .oneOnOne
            displays[message.id] = ChatSenderDisplay(
                name: senderName(for: message.senderBlsPubkeyHex),
                accent: OnymAccent.forSender(blsPubkeyHex: message.senderBlsPubkeyHex),
                showNameHeader: showHeader
            )
            previousSender = message.senderBlsPubkeyHex
        }
        senderDisplays = displays
    }

    /// Resolve the reply quote for a message, if it replies to another.
    /// The target is looked up *live* in the current message list:
    ///   - found → quote carries the target's sender name + accent +
    ///     a one-line body snippet;
    ///   - not on this device (never delivered / deleted) →
    ///     `.unavailable` placeholder.
    /// Returns nil for a non-reply message.
    private func replyQuote(for message: ChatMessage) -> ChatReplyQuote? {
        guard let targetID = message.replyToMessageID else { return nil }
        guard let target = messagesByID[targetID] else { return .unavailable }
        return ChatReplyQuote(
            name: senderName(for: target.senderBlsPubkeyHex),
            snippet: target.body,
            accent: OnymAccent.forSender(blsPubkeyHex: target.senderBlsPubkeyHex),
            isUnavailable: false
        )
    }

    /// Scroll the replied-to message into view and flash it — the
    /// payoff for tapping a quote. No-op if the target isn't in the
    /// current snapshot (it was pruned, or never arrived).
    func scrollAndHighlight(messageID: UUID) {
        guard let indexPath = dataSource.indexPath(for: messageID) else { return }
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        // Flash after the scroll settles so the target cell is mounted
        // and the pulse is visible rather than scrolled past.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let cell = self?.tableView.cellForRow(at: indexPath) as? ChatBubbleCell
            else { return }
            cell.flashHighlight()
        }
    }

    /// The sender's display name: their self-asserted alias when set,
    /// else a short BLS-pubkey fingerprint. Mirrors `ChatMembersView`'s
    /// fallback so an unnamed member reads consistently in both places.
    private func senderName(for blsPubkeyHex: String) -> String {
        let alias = memberProfiles[blsPubkeyHex]?.alias ?? ""
        if !alias.isEmpty { return alias }
        return "BLS " + String(blsPubkeyHex.prefix(8))
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

    /// The keyboard is changing frame: shift the message list's content
    /// up (or down) by the same distance the keyboard's top edge moves,
    /// animated on the keyboard's own duration + curve. Because the
    /// input panel is glued to the keyboard top and the table's bottom
    /// to the input panel, the table shrinks/grows by exactly that
    /// distance — so translating the content by it keeps every visible
    /// message, the latest included, pinned in place relative to the
    /// input area while the keyboard slides.
    ///
    /// This works regardless of whether the `keyboardLayoutGuide`-driven
    /// table resize has been applied yet: the shift is `contentOffset +
    /// delta`, and `contentOffset` is unchanged by a bounds resize, so
    /// the target is correct either way. (Scrolling after the fact, in
    /// `keyboardDidShow`, read as a late jump — this rides the same
    /// animation as the keyboard.)
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let beginFrame = (info[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue,
            let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
            let curveRaw = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
        else { return }

        // How far the keyboard's top edge travels in our coordinates —
        // positive when rising. The table's bottom moves the same amount.
        let endTop = view.convert(endFrame, from: view.window).minY
        let beginTop = view.convert(beginFrame, from: view.window).minY
        let delta = beginTop - endTop
        guard abs(delta) > 0.5 else { return }

        // Final visible table height once the keyboard settles, derived
        // from the keyboard's end frame (not the current bounds, which
        // may or may not have resized yet) so the clamp is correct
        // regardless of layout ordering.
        let panelBottom = min(endTop, view.bounds.maxY - view.safeAreaInsets.bottom)
        let finalViewportHeight = max(0, panelBottom - tableView.frame.minY - inputPanel.bounds.height)

        let target = Self.keyboardAdjustedOffsetY(
            currentOffsetY: tableView.contentOffset.y,
            delta: delta,
            contentHeight: tableView.contentSize.height,
            finalViewportHeight: finalViewportHeight,
            topInset: tableView.adjustedContentInset.top,
            bottomInset: tableView.adjustedContentInset.bottom
        )
        guard abs(target - tableView.contentOffset.y) > 0.5 else { return }

        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
            .union(.beginFromCurrentState)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.tableView.contentOffset.y = target
        }
    }

    /// Translate the content offset by `delta` and clamp it to the
    /// table's scrollable range for the post-keyboard viewport. Pure +
    /// static so the clamp logic is unit-tested without a live keyboard.
    static func keyboardAdjustedOffsetY(
        currentOffsetY: CGFloat,
        delta: CGFloat,
        contentHeight: CGFloat,
        finalViewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let minY = -topInset
        let maxY = max(minY, contentHeight + bottomInset - finalViewportHeight)
        return min(max(currentOffsetY + delta, minY), maxY)
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
        // Hidden until the cold open is positioned at the bottom, so the
        // user never sees the initial top→bottom scroll. Revealed by
        // `jumpToBottomForColdOpen` once the latest message is in place.
        tableView.alpha = 0
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
                let sender = self?.senderDisplays[id] ?? .unknown
                let reply = self?.replyQuote(for: message)
                let quoteTap: (() -> Void)? = {
                    // Only an available target is worth jumping to.
                    guard let targetID = message.replyToMessageID,
                          reply?.isUnavailable == false else { return nil }
                    return { [weak self] in self?.scrollAndHighlight(messageID: targetID) }
                }()
                bubble.configure(
                    message: message,
                    sender: sender,
                    reply: reply,
                    onRetry: retryHandler,
                    onQuoteTapped: quoteTap,
                    onSwipeToReply: { [weak self] in self?.armReply(for: id) },
                    imageLoader: self?.imageLoader,
                    onImageTapped: message.imageAttachment == nil
                        ? nil
                        : { [weak self] in self?.onImageTapped?(message) }
                )
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
            self?.handleSend(body)
        }
        // Tapping the banner's cancel button disarms the reply.
        inputPanel.onCancelReply = { [weak self] in
            self?.clearReply()
        }
        inputPanel.onAttachTapped = { [weak self] in
            self?.onAttachTapped?()
        }
    }

    /// Dispatch a send with the currently-armed reply target (if any),
    /// then clear the composer + the reply banner. Routed through here
    /// so the send tap and the test seam share one path.
    private func handleSend(_ body: String) {
        onSendTapped?(body, replyingTo)
        inputPanel.text = ""
        clearReply()
    }

    /// Arm a reply to `messageID`: remember the target, show the
    /// composer banner with the quoted sender + snippet, and raise the
    /// keyboard so the user can type straight away. No-op if the target
    /// isn't in the current list.
    private func armReply(for messageID: UUID) {
        guard let target = messagesByID[messageID] else { return }
        replyingTo = messageID
        inputPanel.showReplyBanner(
            name: senderName(for: target.senderBlsPubkeyHex),
            snippet: target.body,
            accent: OnymAccent.forSender(blsPubkeyHex: target.senderBlsPubkeyHex)
        )
        inputPanel.focusComposer()
    }

    /// Disarm the reply and hide the banner.
    private func clearReply() {
        replyingTo = nil
        inputPanel.clearReplyBanner()
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

    #if DEBUG
    /// Test seam — drives the same send path the input panel's Send
    /// button would, so tests can assert the armed reply target is
    /// forwarded and then cleared.
    func simulateSendForTest(body: String) {
        handleSend(body)
    }
    #endif
}

extension ChatThreadViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Never begin a pop at the stack root — it leaves the nav
        // controller wedged half-transitioned.
        guard (navigationController?.viewControllers.count ?? 0) > 1 else { return false }

        // The full-width pan should only claim rightward, mostly-
        // horizontal swipes — otherwise it would swallow the message
        // list's vertical scroll. The system edge gesture has no
        // translation to inspect, so let it through unconditionally.
        if gestureRecognizer === fullWidthPanGesture, let pan = fullWidthPanGesture {
            let velocity = pan.velocity(in: view)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
        }
        return true
    }
}
