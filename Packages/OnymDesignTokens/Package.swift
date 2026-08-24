// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymDesignTokens",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymDesignTokens", targets: ["OnymDesignTokens"])
    ],
    targets: [
        .target(name: "OnymDesignTokens")
    ]
)
