// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymDiscovery",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymDiscovery", targets: ["OnymDiscovery"]),
    ],
    dependencies: [
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymDiscovery",
            dependencies: [
                "OnymFoundation",
            ]
        ),
        .testTarget(
            name: "OnymDiscoveryTests",
            dependencies: ["OnymDiscovery"],
            resources: [
                // Byte-exact conformance fixtures copied from
                // onym-discovery/tests/fixtures — `.copy` (not
                // `.process`) so the bytes land in the bundle untouched;
                // signatures and digests are over these exact bytes.
                .copy("Fixtures"),
            ]
        ),
    ]
)
