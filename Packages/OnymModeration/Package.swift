// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymModeration",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymModeration", targets: ["OnymModeration"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymModeration",
            dependencies: [
                "OnymFoundation",
            ]
        ),
    ]
)
