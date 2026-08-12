// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowMobile",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BurrowMobile", targets: ["BurrowMobile"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../ClientCore"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "BurrowMobile",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "BurrowDesignSystem", package: "DesignSystem"),
            ],
            path: "Sources/BurrowMobile"
        ),
        .testTarget(
            name: "BurrowMobileTests",
            dependencies: ["BurrowMobile"],
            path: "Tests/BurrowMobileTests"
        ),
    ]
)
