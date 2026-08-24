// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymDesign",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymDesign", targets: ["OnymDesign"])
    ],
    dependencies: [
        // The swappable token layer. Adopters who want a differently
        // styled build repoint this one dependency at their own module
        // named `OnymDesignTokens` — see that package's README.
        .package(path: "../OnymDesignTokens")
    ],
    targets: [
        .target(
            name: "OnymDesign",
            dependencies: [.product(name: "OnymDesignTokens", package: "OnymDesignTokens")]
        )
    ]
)
