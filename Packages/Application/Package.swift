// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowApplication",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BurrowApplication", targets: ["BurrowApplication"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../Host"),
        .package(path: "../ClientCore"),
        .package(path: "../StateStore"),
        .package(path: "../LocalTransport"),
        // Kept as a composition dependency for the renderer-backed desktop
        // entry point. BurrowApplication itself never imports SwiftTerm/AppKit.
        .package(path: "../TerminalRenderer"),
    ],
    targets: [
        .target(
            name: "BurrowApplication",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "BurrowHost", package: "Host"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "BurrowStateStore", package: "StateStore"),
                .product(name: "BurrowLocalTransport", package: "LocalTransport"),
                .product(name: "BurrowTerminalRenderer", package: "TerminalRenderer"),
            ],
            path: "Sources/BurrowApplication"
        ),
        .testTarget(
            name: "BurrowApplicationTests",
            dependencies: [
                "BurrowApplication",
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "BurrowHost", package: "Host"),
                .product(name: "BurrowStateStore", package: "StateStore"),
            ],
            path: "Tests/BurrowApplicationTests"
        ),
    ]
)
