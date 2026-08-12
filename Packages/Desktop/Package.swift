// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowDesktop",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BurrowDesktop", targets: ["BurrowDesktop"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../ClientCore"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "BurrowDesktop",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "BurrowDesignSystem", package: "DesignSystem"),
            ],
            path: "Sources/BurrowDesktop"
        ),
        .testTarget(
            name: "BurrowDesktopTests",
            dependencies: [
                "BurrowDesktop",
                .product(name: "BurrowDesignSystem", package: "DesignSystem"),
            ],
            path: "Tests/BurrowDesktopTests"
        ),
    ]
)
