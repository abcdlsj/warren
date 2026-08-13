// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenApplication",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WarrenApplication", targets: ["WarrenApplication"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../Host"),
        .package(path: "../ClientCore"),
        .package(path: "../StateStore"),
        .package(path: "../LocalTransport"),
        // Kept as a composition dependency for the renderer-backed desktop
        // entry point. WarrenApplication itself never imports SwiftTerm/AppKit.
        .package(path: "../TerminalRenderer"),
    ],
    targets: [
        .target(
            name: "WarrenApplication",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenHost", package: "Host"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenStateStore", package: "StateStore"),
                .product(name: "WarrenLocalTransport", package: "LocalTransport"),
                .product(name: "WarrenTerminalRenderer", package: "TerminalRenderer"),
            ],
            path: "Sources/WarrenApplication"
        ),
        .testTarget(
            name: "WarrenApplicationTests",
            dependencies: [
                "WarrenApplication",
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenHost", package: "Host"),
                .product(name: "WarrenStateStore", package: "StateStore"),
            ],
            path: "Tests/WarrenApplicationTests"
        ),
    ]
)
