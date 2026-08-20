// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnymBackupUI",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "OnymBackupUI", targets: ["OnymBackupUI"]),
    ],
    dependencies: [
        .package(path: "../OnymBackup"),
        .package(path: "../OnymBilling"),
        .package(path: "../OnymDesign"),
        .package(path: "../OnymFoundation"),
    ],
    targets: [
        .target(
            name: "OnymBackupUI",
            dependencies: [
                "OnymBackup",
                "OnymBilling",
                "OnymDesign",
                "OnymFoundation",
            ]
        ),
    ]
)
