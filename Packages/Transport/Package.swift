// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowTransport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowTransport", targets: ["BurrowTransport"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../ClientCore"),
    ],
    targets: [
        .target(
            name: "BurrowTransport",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
            ],
            path: "Sources/BurrowTransport"
        ),
        .testTarget(
            name: "BurrowTransportTests",
            dependencies: ["BurrowTransport"],
            path: "Tests/BurrowTransportTests"
        ),
    ]
)
