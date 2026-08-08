// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymIdentityUI",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymIdentityUI", targets: ["OnymIdentityUI"])
    ],
    dependencies: [
        .package(path: "../OnymIdentity"),
        .package(path: "../OnymDesign")
    ],
    targets: [
        .target(
            name: "OnymIdentityUI",
            dependencies: ["OnymIdentity", "OnymDesign"]
        )
    ]
)
