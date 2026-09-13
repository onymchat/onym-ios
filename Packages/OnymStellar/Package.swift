// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymStellar",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymStellar", targets: ["OnymStellar"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymStellar",
            dependencies: ["OnymFoundation"]
        ),
        .testTarget(
            name: "OnymStellarTests",
            dependencies: ["OnymStellar"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
