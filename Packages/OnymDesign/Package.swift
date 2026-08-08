// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymDesign",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymDesign", targets: ["OnymDesign"])
    ],
    targets: [
        .target(name: "OnymDesign")
    ]
)
