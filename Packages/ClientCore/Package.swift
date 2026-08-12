// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowClientCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowClientCore", targets: ["BurrowClientCore"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
    ],
    targets: [
        .target(
            name: "BurrowClientCore",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
            ],
            path: "Sources/BurrowClientCore"
        ),
        .testTarget(
            name: "BurrowClientCoreTests",
            dependencies: ["BurrowClientCore"],
            path: "Tests/BurrowClientCoreTests"
        ),
    ]
)
