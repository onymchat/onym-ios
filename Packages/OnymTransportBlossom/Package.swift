// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymTransportBlossom",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymTransportBlossom", targets: ["OnymTransportBlossom"])
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymTransport"),
        .package(path: "../OnymTransportNostr"),
    ],
    targets: [
        .target(
            name: "OnymTransportBlossom",
            dependencies: [
                "OnymFoundation",
                "OnymTransport",
                "OnymTransportNostr",
            ]
        )
    ]
)
