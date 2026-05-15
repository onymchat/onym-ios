import Foundation

/// Seam over the app's composition root. The production conformer is
/// `OnymIOSApp` itself (whose `init` wires the live graph); UI-test and
/// preview hosts can adopt this to vend a hand-built `AppDependencies`
/// without dragging in the full `WindowGroup` lifecycle.
@MainActor
protocol Assembly {
    func assemble() -> AppDependencies
}
