import SwiftUI
import UIKit

/// Top-level chat-screen controller. UIKit-first per the design call
/// (#150 plan): the message list and input panel are UIKit. SwiftUI
/// hosts this controller via `ChatThreadView`.
///
/// The navigation bar (title, member count, back button, group-info
/// button) lives in the surrounding SwiftUI `NavigationStack` — the
/// controller no longer paints its own top bar, so the app shows a
/// single, consistent (Liquid Glass) system back button whether the
/// thread is opened from the Chats list or from Search.
final class ChatThreadViewController: UIViewController {
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
    /// Loader used by voice bubbles to fetch + decrypt audio for playback.
    var voiceLoader: ChatVoiceLoader?
    /// Fired when a message's image is tapped (host presents full-screen).
    var onImageTapped: ((ChatMessage) -> Void)?
    /// Fired when a message's video poster is tapped (host presents the
    /// full-screen player).
    var onVideoTapped: ((ChatMessage) -> Void)?
    /// Fired when a *failed* outgoing attachment is tapped (host presents
    /// the Resend / Delete menu).
    var onAttachmentActionsRequested: ((ChatMessage) -> Void)?
    /// Fired when an album tile is tapped (host opens the full-screen
    /// gallery at that item index).
    var onAlbumItemTapped: ((ChatMessage, Int) -> Void)?
    /// When set (e.g. opened from Search), the cold open lands on this
    /// message — scrolled to the middle and flashed — instead of at the
    /// bottom. Cleared after it's consumed so later snapshots behave
    /// normally.
    var openAtMessageID: UUID?
    /// Fired when the composer's attach button is tapped (host presents
    /// the combined photo/video picker).
    var onAttachTapped: (() -> Void)?
    /// Fired when a voice message finishes recording (host encrypts +
    /// uploads it). Receives the recorded `.m4a` file URL.
    var onSendVoiceTapped: ((URL) -> Void)?
    /// Fired when Send is tapped with media staged in the preview strip
    /// (host sends the album + clears the strip).
    var onSendMedia: (() -> Void)?
    /// Fired when the ✕ on a staged item is tapped (host drops it).
    var onRemovePendingMedia: ((UUID) -> Void)?

    private let tableView = UITableView()
    /// The group's invitation message, surfaced in the empty state.
    private var invitationMessage: String?
    /// Rich empty state (invitation + members + privacy points), hosted
    /// in the message-list region above the composer. Shown only when the
    /// thread has no messages.
    private lazy var emptyStateHost = UIHostingController(rootView: makeEmptyState())
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

    // Widen the back-swipe target: alongside the system edge gesture,
    // install a full-width pan that drives the *same* interactive pop
    // transition — so a swipe anywhere on the chat screen goes back to
    // the list, not just from the screen edge.
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
        // Refresh the empty state's member roster.
        emptyStateHost.rootView = makeEmptyState()

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
        // Only a genuinely *new* row pulls the scroll along. A same-count
        // update is a `reconfigureItems` — a status flip (pending → sent →
        // delivered → read) or a body/attachment repaint — and re-scrolling
        // on those made the thread jump up and down every time a receipt
        // landed for the just-sent message.
        let previousCount = orderedMessages.count

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

        // Empty state: visible iff the message list is empty. Toggling
        // `isHidden` is cheap and survives keyboard show/hide.
        emptyStateHost.view.isHidden = !sorted.isEmpty

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
            } else if wasNearBottom && sorted.count > previousCount {
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
        // Opened-from-search: land on the target message rather than the
        // bottom. Position without animation (masked while the table is
        // still hidden), then flash it once revealed.
        if let target = openAtMessageID, dataSource.indexPath(for: target) != nil {
            openAtMessageID = nil
            if let indexPath = dataSource.indexPath(for: target) {
                tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let indexPath = self.dataSource.indexPath(for: target) {
                    self.tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
                    if let cell = self.tableView.cellForRow(at: indexPath) as? ChatBubbleCell {
                        cell.flashHighlight()
                    }
                }
                if self.tableView.alpha == 0 { self.tableView.alpha = 1 }
            }
            return
        }
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
        // Two reuse pools (text vs media/voice) so a text bubble never
        // recycles a cell that still carries a media width lock.
        tableView.register(ChatBubbleCell.self, forCellReuseIdentifier: ChatBubbleCell.textReuseID)
        tableView.register(ChatBubbleCell.self, forCellReuseIdentifier: ChatBubbleCell.mediaReuseID)
        tableView.keyboardDismissMode = .interactive
        view.addSubview(tableView)

        // Empty state — a hosted SwiftUI view filling the message-list
        // region (above the input panel). Shown when the list is empty,
        // hidden as soon as the first message arrives. Scrollable so its
        // invitation + members + privacy content never gets clipped or
        // covered when the keyboard rises.
        addChild(emptyStateHost)
        emptyStateHost.view.backgroundColor = .clear
        emptyStateHost.view.translatesAutoresizingMaskIntoConstraints = false
        emptyStateHost.view.isHidden = true
        emptyStateHost.view.accessibilityIdentifier = "chat.empty_state"
        view.addSubview(emptyStateHost.view)
        emptyStateHost.didMove(toParent: self)
    }

    /// Rebuild the empty-state SwiftUI view from the latest group
    /// metadata (invitation + member aliases).
    private func makeEmptyState() -> ChatEmptyStateView {
        let names = memberProfiles.values
            .map { $0.alias.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.isEmpty ? "(unnamed)" : $0 }
            .sorted { $0.lowercased() < $1.lowercased() }
        return ChatEmptyStateView(invitationMessage: invitationMessage, memberNames: names)
    }

    /// Push the group's invitation message in (for the empty state).
    /// Called by the SwiftUI wrapper on every render; refreshes the
    /// empty state when it changes.
    func update(invitationMessage: String?) {
        guard invitationMessage != self.invitationMessage else { return }
        self.invitationMessage = invitationMessage
        emptyStateHost.rootView = makeEmptyState()
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Section, UUID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, id in
            // Pick the reuse pool from the message content so a text bubble
            // never recycles a media cell (with its 75%-width lock still on).
            let message = self?.messagesByID[id]
            let reuseID = (message.map(ChatBubbleCell.hasMedia) ?? false)
                ? ChatBubbleCell.mediaReuseID
                : ChatBubbleCell.textReuseID
            let cell = tableView.dequeueReusableCell(
                withIdentifier: reuseID,
                for: indexPath
            )
            if let bubble = cell as? ChatBubbleCell,
               let message {
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
                // A failed outgoing attachment taps into the Resend /
                // Delete menu instead of the full-screen viewer/gallery or
                // (for voice) inline playback.
                let isFailedOutgoingAttachment = message.direction == .outgoing
                    && message.status == .failed
                    && (!message.media.isEmpty || message.voiceAttachment != nil)
                let imageTap: (() -> Void)? = message.imageAttachment == nil ? nil : { [weak self] in
                    if isFailedOutgoingAttachment { self?.onAttachmentActionsRequested?(message) }
                    else { self?.onImageTapped?(message) }
                }
                let videoTap: (() -> Void)? = message.videoAttachment == nil ? nil : { [weak self] in
                    if isFailedOutgoingAttachment { self?.onAttachmentActionsRequested?(message) }
                    else { self?.onVideoTapped?(message) }
                }
                let albumTap: ((Int) -> Void)? = message.media.count > 1 ? { [weak self] index in
                    if isFailedOutgoingAttachment { self?.onAttachmentActionsRequested?(message) }
                    else { self?.onAlbumItemTapped?(message, index) }
                } : nil
                // A failed voice bubble routes taps to the Resend/Delete
                // menu; otherwise the cell handles play/pause internally.
                let voiceFailedTap: (() -> Void)? = (isFailedOutgoingAttachment
                    && message.voiceAttachment != nil) ? { [weak self] in
                        self?.onAttachmentActionsRequested?(message)
                    } : nil
                bubble.configure(
                    message: message,
                    sender: sender,
                    reply: reply,
                    onRetry: retryHandler,
                    onQuoteTapped: quoteTap,
                    onSwipeToReply: { [weak self] in self?.armReply(for: id) },
                    imageLoader: self?.imageLoader,
                    voiceLoader: self?.voiceLoader,
                    onImageTapped: imageTap,
                    onVideoTapped: videoTap,
                    onAlbumItemTapped: albumTap,
                    onVoiceFailedTapped: voiceFailedTap
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
        inputPanel.onSendVoiceTapped = { [weak self] url in
            self?.onSendVoiceTapped?(url)
        }
        inputPanel.onSendMediaTapped = { [weak self] in
            self?.onSendMedia?()
        }
        inputPanel.onRemovePendingMedia = { [weak self] id in
            self?.onRemovePendingMedia?(id)
        }
    }

    /// Stage picked media in the composer's preview strip (host owns the
    /// selection; passes fresh thumbnails on every change).
    func setPendingMedia(_ items: [(id: UUID, thumbnail: UIImage)]) {
        inputPanel.setPendingMedia(items)
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
            // Table view — fills the space between the SwiftUI navigation
            // bar (safe-area top) and the input panel. The title bar +
            // back button now live in the surrounding SwiftUI nav bar.
            tableView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputPanel.topAnchor),

            // Empty state — fills the same region the table view
            // occupies (message list, above the composer). Toggled on
            // when the message list is empty.
            emptyStateHost.view.topAnchor.constraint(equalTo: tableView.topAnchor),
            emptyStateHost.view.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
            emptyStateHost.view.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            emptyStateHost.view.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),

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
