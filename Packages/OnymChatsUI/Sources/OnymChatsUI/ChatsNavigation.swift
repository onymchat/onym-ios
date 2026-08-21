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
/// `NavigationPath` rather than a typed array because the stack pushes
/// two kinds of value: a group id (`String`) for a real thread and a
/// `PendingChatRoute` for one that hasn't opened yet.
@MainActor
@Observable
public final class ChatsNavigation {
    public var path = NavigationPath()
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
        path.append(groupID)
        focusRequests += 1
    }

    /// Open a chat that is still on its way in.
    public func openPending(rowID: String) {
        path.append(PendingChatRoute(id: rowID))
        focusRequests += 1
    }

    /// The wait ended while the person was watching it: drop the pending
    /// screen and put the real thread in its place.
    ///
    /// A replacement rather than a push, because the pending screen has
    /// nothing left to show — its row is gone — and leaving it under the
    /// thread would put a dead screen behind the Back button of the chat
    /// the user just got into.
    public func replaceTopWithChat(groupID: String) {
        if !path.isEmpty { path.removeLast() }
        path.append(groupID)
        // No focus bump: this one only happens while the person is
        // already looking at the screen being replaced.
    }
}

/// Navigation value for a chat that hasn't opened yet. A distinct type
/// rather than another `String`: a pending row's id and a group id would
/// otherwise share a value space, and a stale one would open the wrong
/// screen.
public struct PendingChatRoute: Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
