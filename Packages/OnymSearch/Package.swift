// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymSearch",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymSearch", targets: ["OnymSearch"])
    ],
    dependencies: [
        .package(path: "../OnymChatsCore"),
        .package(path: "../OnymIdentity")
    ],
    targets: [
        .target(
            name: "OnymSearch",
            dependencies: [
                "OnymChatsCore",
                "OnymIdentity"
            ]
        )
    ]
)
