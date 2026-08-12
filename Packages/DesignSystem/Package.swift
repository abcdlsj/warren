// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowDesignSystem",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowDesignSystem", targets: ["BurrowDesignSystem"]),
    ],
    targets: [
        .target(
            name: "BurrowDesignSystem",
            path: "Sources/BurrowDesignSystem"
        ),
        .testTarget(
            name: "BurrowDesignSystemTests",
            dependencies: ["BurrowDesignSystem"],
            path: "Tests/BurrowDesignSystemTests"
        ),
    ]
)
