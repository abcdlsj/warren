// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenLocalTransport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenLocalTransport", targets: ["WarrenLocalTransport"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../Host"),
        .package(path: "../ClientCore"),
    ],
    targets: [
        .target(
            name: "WarrenLocalTransport",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenHost", package: "Host"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
            ],
            path: "Sources/WarrenLocalTransport"
        ),
        .testTarget(
            name: "WarrenLocalTransportTests",
            dependencies: ["WarrenLocalTransport"],
            path: "Tests/WarrenLocalTransportTests"
        ),
    ]
)
