// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowTerminalRenderer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowTerminalRenderer", targets: ["BurrowTerminalRenderer"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../ClientCore"),
    ],
    targets: [
        .target(
            name: "BurrowTerminalRenderer",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
            ],
            path: "Sources/BurrowTerminalRenderer"
        ),
        .testTarget(
            name: "BurrowTerminalRendererTests",
            dependencies: ["BurrowTerminalRenderer"],
            path: "Tests/BurrowTerminalRendererTests"
        ),
    ]
)
