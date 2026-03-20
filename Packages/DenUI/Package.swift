// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenUI", targets: ["DenUI"]),
    ],
    dependencies: [
        .package(path: "../DenCore"),
    ],
    targets: [
        .target(
            name: "DenUI",
            dependencies: ["DenCore"],
            path: "Sources/DenUI"
        ),
    ]
)
