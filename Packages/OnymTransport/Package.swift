// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OnymTransport",
    // macOS only so packages that test on a Mac (OnymMesh) can build it.
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [
        .library(name: "OnymTransport", targets: ["OnymTransport"])
    ],
    targets: [
        .target(name: "OnymTransport")
    ]
)
