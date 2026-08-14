// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymFoundation",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymFoundation", targets: ["OnymFoundation"]),
    ],
    targets: [
        .target(name: "OnymFoundation"),
        .testTarget(
            name: "OnymFoundationTests",
            dependencies: ["OnymFoundation"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
