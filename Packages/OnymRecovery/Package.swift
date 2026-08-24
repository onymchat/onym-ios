// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymRecovery",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymRecovery", targets: ["OnymRecovery"])
    ],
    dependencies: [
        .package(path: "../OnymIdentity"),
        // Tokens only — this package draws with the design's colors and
        // radii but uses none of OnymDesign's components.
        .package(path: "../OnymDesignTokens")
    ],
    targets: [
        .target(
            name: "OnymRecovery",
            dependencies: [
                "OnymIdentity",
                .product(name: "OnymDesignTokens", package: "OnymDesignTokens")
            ]
        )
    ]
)
