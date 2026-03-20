// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenCore", targets: ["DenCore"]),
    ],
    targets: [
        .target(
            name: "DenCore",
            path: "Sources/DenCore"
        ),
        .executableTarget(
            name: "DenCoreTests",
            dependencies: ["DenCore"],
            path: "Tests/DenCoreTests"
        ),
    ]
)
