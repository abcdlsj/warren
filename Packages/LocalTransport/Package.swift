// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowLocalTransport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowLocalTransport", targets: ["BurrowLocalTransport"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../Host"),
        .package(path: "../ClientCore"),
    ],
    targets: [
        .target(
            name: "BurrowLocalTransport",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "BurrowHost", package: "Host"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
            ],
            path: "Sources/BurrowLocalTransport"
        ),
        .testTarget(
            name: "BurrowLocalTransportTests",
            dependencies: ["BurrowLocalTransport"],
            path: "Tests/BurrowLocalTransportTests"
        ),
    ]
)
