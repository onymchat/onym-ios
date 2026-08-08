// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymChain",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymChain", targets: ["OnymChain"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
        .package(url: "https://github.com/onymchat/onym-sdk-swift.git", from: "0.0.2"),
    ],
    targets: [
        .target(
            name: "OnymChain",
            dependencies: [
                "OnymFoundation",
                .product(name: "OnymSDK", package: "onym-sdk-swift"),
            ]
        ),
    ]
)
