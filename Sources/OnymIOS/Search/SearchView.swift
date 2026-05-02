import SwiftUI

/// Search tab placeholder. Real search lands in a future chunk; this
/// view exists so the iOS 18 `.search` role tab in `RootView` has a
/// destination, which keeps the system search slot rendered in the
/// bottom-right of the tab strip.
struct SearchView: View {
    var body: some View {
        ContentUnavailableView(
            "Search",
            systemImage: "magnifyingglass",
            description: Text("Search lands in a later chunk.")
        )
        .navigationTitle("Search")
    }
}
