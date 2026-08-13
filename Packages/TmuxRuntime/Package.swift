// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenTmuxRuntime",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WarrenTmuxRuntime", targets: ["WarrenTmuxRuntime"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Host"),
    ],
    targets: [
        .target(
            name: "WarrenTmuxRuntime",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenHost", package: "Host"),
            ],
            path: "Sources/WarrenTmuxRuntime"
        ),
        .testTarget(
            name: "WarrenTmuxRuntimeTests",
            dependencies: ["WarrenTmuxRuntime"],
            path: "Tests/WarrenTmuxRuntimeTests"
        ),
    ]
)
