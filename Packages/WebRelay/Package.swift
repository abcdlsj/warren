// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WebRelay",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WebRelay", targets: ["WebRelay"]),
    ],
    dependencies: [
        .package(path: "../Application"),
        .package(path: "../Domain"),
        .package(path: "../Host"),
        .package(path: "../StateStore"),
    ],
    targets: [
        .target(
            name: "WebRelay",
            dependencies: [
                .product(name: "WarrenApplication", package: "Application"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenHost", package: "Host"),
            ],
            resources: [
                .copy("Resources/web.html"),
                .copy("Resources/manifest.webmanifest"),
                .copy("Resources/service-worker.js"),
                .copy("Resources/icon.svg"),
                .copy("Resources/icon-192.png"),
                .copy("Resources/icon-512.png"),
                .copy("Resources/apple-touch-icon.png"),
                .copy("Resources/preset-shell.svg"),
                .copy("Resources/preset-claude.svg"),
                .copy("Resources/preset-codex.svg"),
                .copy("Resources/preset-codex-white.svg")
            ]
        ),
        .testTarget(
            name: "WebRelayTests",
            dependencies: [
                "WebRelay",
                .product(name: "WarrenHost", package: "Host"),
                .product(name: "WarrenStateStore", package: "StateStore"),
            ]
        ),
    ]
)
