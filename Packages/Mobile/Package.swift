// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenMobile",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WarrenMobile", targets: ["WarrenMobile"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../ClientCore"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "WarrenMobile",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenDesignSystem", package: "DesignSystem"),
            ],
            path: "Sources/WarrenMobile"
        ),
        .testTarget(
            name: "WarrenMobileTests",
            dependencies: ["WarrenMobile"],
            path: "Tests/WarrenMobileTests"
        ),
    ]
)
