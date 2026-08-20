// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymBilling",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymBilling", targets: ["OnymBilling"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymBilling",
            dependencies: [
                "OnymFoundation",
            ]
        ),
    ]
)
