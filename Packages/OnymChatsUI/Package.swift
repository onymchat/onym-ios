// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymChatsUI",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymChatsUI", targets: ["OnymChatsUI"])
    ],
    dependencies: [
        .package(path: "../OnymChatsCore"),
        .package(path: "../OnymInbox"),
        .package(path: "../OnymGroup"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymIdentityUI"),
        .package(path: "../OnymDesign"),
        .package(path: "../OnymDesignTokens"),
        .package(path: "../OnymChain"),
        .package(path: "../OnymModeration")
    ],
    targets: [
        .target(
            name: "OnymChatsUI",
            dependencies: [
                "OnymChatsCore",
                "OnymInbox",
                "OnymGroup",
                "OnymIdentity",
                "OnymIdentityUI",
                "OnymDesign",
                .product(name: "OnymDesignTokens", package: "OnymDesignTokens"),
                "OnymChain",
                "OnymModeration"
            ]
        )
    ]
)
