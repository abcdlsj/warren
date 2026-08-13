// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenHost",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenHost", targets: ["WarrenHost"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
    ],
    targets: [
        .target(
            name: "WarrenHost",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
            ],
            path: "Sources/WarrenHost"
        ),
        .testTarget(
            name: "WarrenHostTests",
            dependencies: ["WarrenHost"],
            path: "Tests/WarrenHostTests"
        ),
    ]
)
