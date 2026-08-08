// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymRecovery",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymRecovery", targets: ["OnymRecovery"])
    ],
    dependencies: [
        .package(path: "../OnymIdentity")
    ],
    targets: [
        .target(
            name: "OnymRecovery",
            dependencies: [
                "OnymIdentity"
            ]
        )
    ]
)
