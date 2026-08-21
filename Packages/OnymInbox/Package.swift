// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymInbox",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymInbox", targets: ["OnymInbox"])
    ],
    dependencies: [
        .package(path: "../OnymChatsCore"),
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymGroup"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymChain"),
        .package(path: "../OnymTransport"),
        .package(path: "../OnymPersistence"),
        .package(path: "../OnymDesign"),
    ],
    targets: [
        .target(
            name: "OnymInbox",
            dependencies: [
                "OnymChatsCore",
                "OnymFoundation",
                "OnymGroup",
                "OnymIdentity",
                "OnymChain",
                "OnymTransport",
                "OnymPersistence",
                "OnymDesign",
            ]
        )
    ]
)
