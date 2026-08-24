// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymOnboarding",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymOnboarding", targets: ["OnymOnboarding"]),
    ],
    dependencies: [
        // Tokens only. The rule below still holds — this is the
        // zero-dependency value layer, not a UI package — and without
        // it the onboarding screens would be the one part of the app
        // an adopter's theme could not reach.
        .package(path: "../OnymDesignTokens"),
    ],
    targets: [
        // No UI package dependencies: the flow models each step's
        // outcome abstractly and receives every collaborator as an
        // injected closure, so the state machine never links against
        // OnymDiscovery / OnymModerationUI / OnymDesign. The app's
        // composition root (PR 3) supplies the step content and the
        // step indicator from those packages.
        .target(
            name: "OnymOnboarding",
            dependencies: [
                .product(name: "OnymDesignTokens", package: "OnymDesignTokens"),
            ]
        ),
        .testTarget(
            name: "OnymOnboardingTests",
            dependencies: ["OnymOnboarding"]
        ),
    ]
)
