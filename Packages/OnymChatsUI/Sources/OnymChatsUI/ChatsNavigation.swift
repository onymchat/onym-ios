import SwiftUI
import Observation

/// The Chats tab's navigation path, hoisted out of the view so something
/// outside the tab can push onto it.
///
/// It exists because a tapped invite link no longer opens a sheet. The
/// link is handled at the app root — above the tab bar, above the
/// navigation stack — and the thing it produces is a row *inside* the
/// chats list. Without a shared path the user would tap a link in
/// Messages, come back, and find nothing had visibly happened.
///
/// The stack pushes two kinds of screen: a real thread, and one that
/// hasn't opened yet.
@MainActor
@Observable
public final class ChatsNavigation {
    /// A typed array rather than `NavigationPath`, because the swap
    /// below has to know what it is replacing. `NavigationPath` exposes
    /// `count` and `removeLast()` and nothing that reads an element, so
    /// a "replace the pending screen" written against it can only pop
    /// whatever happens to be on top — which, with a second link tapped
    /// in the meantime, is the screen the person is reading.
    public var path: [ChatsRoute] = []
    /// Bumped every time something outside the tab pushes onto `path`.
    ///
    /// A push alone isn't enough to be seen: the tab bar is a level
    /// above the stack, so a link tapped while the app was last on
    /// Settings put the chat on an off-screen stack and the user came
    /// back to Settings — "nothing visibly happened", which is the exact
    /// failure hoisting the path was meant to prevent. `RootView`
    /// watches this and selects the Chats tab.
    ///
    /// A counter rather than a flag, so two links in a row are two
    /// requests and neither has to be cleared by whoever handled it.
    public private(set) var focusRequests = 0

    public init() {}

    /// Open a chat this device is already a member of.
    public func openChat(groupID: String) {
        path.append(.chat(groupID: groupID))
        focusRequests += 1
    }

    /// Open a chat that is still on its way in.
    public func openPending(rowID: String) {
        path.append(.pending(rowID: rowID))
        focusRequests += 1
    }

    /// The wait ended while the person was watching it: drop the pending
    /// screen and put the real thread in its place.
    ///
    /// A replacement rather than a push, because the pending screen has
    /// nothing left to show — its row is gone — and leaving it under the
    /// thread would put a dead screen behind the Back button of the chat
    /// the user just got into.
    /// Only when that pending screen is the one on top. A buried
    /// `PendingChatThreadView` is still alive and still watching its
    /// row, so an unguarded `removeLast()` would delete whatever the
    /// person navigated to *after* it and drop them into a chat they
    /// didn't ask for — reliably, whenever two links are in flight.
    public func replaceTopWithChat(rowID: String, groupID: String) {
        guard path.last == .pending(rowID: rowID) else { return }
        path.removeLast()
        path.append(.chat(groupID: groupID))
        // No focus bump: this only happens while the person is already
        // looking at the screen being replaced.
    }
}

/// Everything the Chats stack can push.
///
/// One enum rather than two value types, so a pending row's id and a
/// group id can't be confused for each other — they are both strings,
/// and a stale one would otherwise open the wrong screen.
public enum ChatsRoute: Hashable {
    case chat(groupID: String)
    case pending(rowID: String)
}
