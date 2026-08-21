import SwiftUI

/// An alert driven by an optional reason string: present when it's
/// non-nil, dismiss by clearing it.
///
/// SwiftUI's `alert(_:isPresented:presenting:)` wants a `Bool` binding
/// and a value, so every call site that keeps its reason in a
/// `@State String?` writes the same six-line `Binding(get:set:)` bridge.
/// It appeared twice for the same alert — once where a scanned invite
/// fails, once where a tapped one does — and a third copy was one entry
/// point away.
public extension View {
    func reasonAlert(_ title: LocalizedStringKey, reason: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { reason.wrappedValue != nil },
                set: { if !$0 { reason.wrappedValue = nil } }
            ),
            presenting: reason.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}
