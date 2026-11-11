// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OnymMesh",
    // macOS only so `swift test` runs the codec, tag and reassembly
    // tests on a Mac; nothing here ships there.
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [
        .library(name: "OnymMesh", targets: ["OnymMesh"])
    ],
    dependencies: [
        .package(path: "../OnymTransport"),
    ],
    targets: [
        .target(
            name: "OnymMesh",
            dependencies: ["OnymTransport"]
        ),
        .testTarget(
            name: "OnymMeshTests",
            dependencies: ["OnymMesh"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
