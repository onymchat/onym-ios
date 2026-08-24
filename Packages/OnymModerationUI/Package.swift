// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymModerationUI",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymModerationUI", targets: ["OnymModerationUI"]),
    ],
    dependencies: [
        .package(path: "../OnymModeration"),
        .package(path: "../OnymDesign"),
        .package(path: "../OnymDesignTokens"),
    ],
    targets: [
        .target(
            name: "OnymModerationUI",
            dependencies: [
                "OnymModeration",
                "OnymDesign",
                .product(name: "OnymDesignTokens", package: "OnymDesignTokens"),
            ]
        ),
    ]
)
