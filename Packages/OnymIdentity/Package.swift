// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymIdentity",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymIdentity", targets: ["OnymIdentity"])
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymTransport"),
        .package(url: "https://github.com/onymchat/onym-sdk-swift.git", from: "0.0.2"),
    ],
    targets: [
        .target(
            name: "OnymIdentity",
            dependencies: [
                "OnymFoundation",
                "OnymTransport",
                .product(name: "OnymSDK", package: "onym-sdk-swift"),
            ]
        )
    ]
)
