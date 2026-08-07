// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymGroup",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymGroup", targets: ["OnymGroup"])
    ],
    dependencies: [
        .package(path: "../OnymChain"),
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymTransport"),
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymDesign"),
        .package(url: "https://github.com/onymchat/onym-sdk-swift.git", from: "0.0.2")
    ],
    targets: [
        .target(
            name: "OnymGroup",
            dependencies: [
                "OnymChain",
                "OnymIdentity",
                "OnymTransport",
                "OnymFoundation",
                "OnymDesign",
                .product(name: "OnymSDK", package: "onym-sdk-swift")
            ]
        )
    ]
)
