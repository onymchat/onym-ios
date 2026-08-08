// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymTransportNostr",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymTransportNostr", targets: ["OnymTransportNostr"])
    ],
    dependencies: [
        .package(path: "../OnymTransport"),
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymTransportNostr",
            dependencies: [
                "OnymTransport",
                "OnymFoundation",
            ]
        )
    ]
)
