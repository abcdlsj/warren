// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowProtocol",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowProtocol", targets: ["BurrowProtocol"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "BurrowProtocol",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
            ],
            path: "Sources/BurrowProtocol"
        ),
        .testTarget(
            name: "BurrowProtocolTests",
            dependencies: ["BurrowProtocol"],
            path: "Tests/BurrowProtocolTests"
        ),
    ]
)
