// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymTreasury",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymTreasury", targets: ["OnymTreasury"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymStellar"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymGroup"),
        .package(path: "../OnymTransport"),
        .package(path: "../OnymChain"),
    ],
    targets: [
        .target(
            name: "OnymTreasury",
            dependencies: [
                "OnymFoundation",
                "OnymStellar",
                "OnymIdentity",
                "OnymGroup",
                "OnymTransport",
                "OnymChain",
            ]
        ),
    ]
)
