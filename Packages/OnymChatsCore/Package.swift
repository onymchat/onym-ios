// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymChatsCore",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymChatsCore", targets: ["OnymChatsCore"])
    ],
    dependencies: [
        .package(path: "../OnymGroup"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymTransport"),
        .package(path: "../OnymTransportBlossom"),
        .package(path: "../OnymChain"),
        .package(path: "../OnymFoundation")
    ],
    targets: [
        .target(
            name: "OnymChatsCore",
            dependencies: [
                "OnymGroup",
                "OnymIdentity",
                "OnymTransport",
                "OnymTransportBlossom",
                "OnymChain",
                "OnymFoundation"
            ]
        )
    ]
)
