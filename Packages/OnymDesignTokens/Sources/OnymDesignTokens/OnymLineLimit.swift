import SwiftUI

// MARK: - Line limits that give way

public extension View {
    /// A line limit that lifts at accessibility text sizes.
    ///
    /// `lineLimit(1)` is right for a relay URL or a pubkey: a reader
    /// comparing one character at a time is better served by a truncated
    /// line than by sixty characters wrapped across a card, and those
    /// sites keep the plain modifier deliberately.
    ///
    /// It is wrong for a group name or a row subtitle. At the largest
    /// accessibility size type is 2.82× — a name that fitted on one line
    /// no longer does, and holding it to one line means the reader who
    /// most needs to read it sees the least of it.
    ///
    /// Below the accessibility sizes this behaves exactly like
    /// `lineLimit(_:)`, so nothing moves for readers who never changed
    /// the setting.
    /// - Parameter relaxing: pass `false` where the same component
    ///   sometimes shows a key or a URL — the limit then behaves exactly
    ///   like `lineLimit(_:)`. `Row` uses this: its title relaxes when
    ///   it is a label and holds when it is mono.
    func onymLineLimit(_ limit: Int, relaxing: Bool = true) -> some View {
        modifier(RelaxingLineLimit(limit: limit, relaxing: relaxing))
    }
}

private struct RelaxingLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let limit: Int
    let relaxing: Bool

    func body(content: Content) -> some View {
        content.lineLimit(relaxing && typeSize.isAccessibilitySize ? nil : limit)
    }
}
