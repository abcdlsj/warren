// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenConfig",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenConfig", targets: ["DenConfig"]),
    ],
    targets: [
        .target(
            name: "DenConfig",
            path: "Sources/DenConfig"
        ),
    ]
)
