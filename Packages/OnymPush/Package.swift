// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymPush",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymPush", targets: ["OnymPush"]),
    ],
    targets: [
        .target(name: "OnymPush"),
    ]
)
