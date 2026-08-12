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
                .product(name: "BurrowApplication", package: "Application"),
                .product(name: "BurrowDomain", package: "Domain"),
            ],
            resources: [
                .copy("Resources/web.html")
            ]
        ),
        .testTarget(
            name: "WebRelayTests",
            dependencies: [
                "WebRelay",
                .product(name: "BurrowHost", package: "Host"),
                .product(name: "BurrowStateStore", package: "StateStore"),
            ]
        ),
    ]
)
