// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymOnboarding",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymOnboarding", targets: ["OnymOnboarding"]),
    ],
    targets: [
        // Deliberately dependency-free: the flow models each step's
        // outcome abstractly and receives every collaborator as an
        // injected closure, so the state machine never links against
        // OnymDiscovery / OnymModerationUI / OnymDesign. The app's
        // composition root (PR 3) supplies the step content and the
        // step indicator from those packages.
        .target(
            name: "OnymOnboarding"
        ),
        .testTarget(
            name: "OnymOnboardingTests",
            dependencies: ["OnymOnboarding"]
        ),
    ]
)
