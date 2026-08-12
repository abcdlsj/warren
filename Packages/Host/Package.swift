// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowHost",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowHost", targets: ["BurrowHost"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
    ],
    targets: [
        .target(
            name: "BurrowHost",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
            ],
            path: "Sources/BurrowHost"
        ),
        .testTarget(
            name: "BurrowHostTests",
            dependencies: ["BurrowHost"],
            path: "Tests/BurrowHostTests"
        ),
    ]
)
