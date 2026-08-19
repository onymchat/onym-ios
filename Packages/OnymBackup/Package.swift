// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymBackup",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymBackup", targets: ["OnymBackup"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymBackup",
            dependencies: [
                "OnymFoundation",
            ]
        ),
    ]
)
