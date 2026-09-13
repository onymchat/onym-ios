// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymTreasuryUI",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymTreasuryUI", targets: ["OnymTreasuryUI"]),
    ],
    dependencies: [
        .package(path: "../OnymTreasury"),
        .package(path: "../OnymStellar"),
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymGroup"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymDesign"),
        .package(path: "../OnymDesignTokens"),
    ],
    targets: [
        .target(
            name: "OnymTreasuryUI",
            dependencies: [
                "OnymTreasury",
                "OnymStellar",
                "OnymFoundation",
                "OnymGroup",
                "OnymIdentity",
                "OnymDesign",
                .product(name: "OnymDesignTokens", package: "OnymDesignTokens"),
            ]
        ),
    ]
)
