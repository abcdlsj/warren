// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GhosttyAdapter",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        // Surface rendering and deterministic AppKit focus ownership.
        .library(name: "GhosttyAdapter", targets: ["GhosttyAdapter"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/jiweiyuan/libghostty-swift",
            from: "1.0.15"
        ),
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "GhosttyAdapter",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-swift"),
                .product(name: "GhosttyKit", package: "libghostty-swift"),
                .product(name: "WarrenDomain", package: "Domain"),
            ]
        ),
        .testTarget(
            name: "GhosttyAdapterTests",
            dependencies: ["GhosttyAdapter"]
        ),
    ]
)
