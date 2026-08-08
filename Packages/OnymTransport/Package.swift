// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OnymTransport",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymTransport", targets: ["OnymTransport"])
    ],
    targets: [
        .target(name: "OnymTransport")
    ]
)
