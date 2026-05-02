import SwiftUI

/// Host view that constructs the `CreateGroupFlow` exactly once on
/// first render and wires its `onClose` callback to the parent's
/// dismiss state. Inlining this construction inside `.fullScreenCover`
/// would re-make the flow on every state mutation.
///
/// Lives outside `CreateGroupView.swift` so any tab / screen that
/// wants to present the flow (currently `ChatsView`, future settings
/// shortcuts, etc.) can share the same factory plumbing.
struct CreateGroupViewHost: View {
    let makeFlow: @MainActor () -> CreateGroupFlow
    let onClose: () -> Void

    @State private var flow: CreateGroupFlow?

    var body: some View {
        Group {
            if let flow {
                CreateGroupView(flow: flow)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            if flow == nil {
                let f = makeFlow()
                f.onClose = onClose
                flow = f
            }
        }
    }
}
