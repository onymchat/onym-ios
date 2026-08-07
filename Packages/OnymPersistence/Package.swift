// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymPersistence",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymPersistence", targets: ["OnymPersistence"])
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
        .package(path: "../OnymIdentity")
    ],
    targets: [
        .target(
            name: "OnymPersistence",
            dependencies: [
                "OnymFoundation",
                "OnymIdentity"
            ]
        )
    ]
)
