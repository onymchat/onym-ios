// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymSettings",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymSettings", targets: ["OnymSettings"]),
    ],
    dependencies: [
        .package(path: "../OnymChain"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymIdentityUI"),
        .package(path: "../OnymRecovery"),
        .package(path: "../OnymTransportNostr"),
        .package(path: "../OnymTransportBlossom"),
        .package(path: "../OnymChatsCore"),
        .package(path: "../OnymDesign"),
        .package(path: "../OnymModeration"),
        .package(path: "../OnymModerationUI"),
    ],
    targets: [
        .target(
            name: "OnymSettings",
            dependencies: [
                "OnymChain",
                "OnymIdentity",
                "OnymIdentityUI",
                "OnymRecovery",
                "OnymTransportNostr",
                "OnymTransportBlossom",
                "OnymChatsCore",
                "OnymDesign",
                "OnymModeration",
                "OnymModerationUI",
            ]
        ),
    ]
)
