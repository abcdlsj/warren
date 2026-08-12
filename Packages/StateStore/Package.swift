// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowStateStore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowStateStore", targets: ["BurrowStateStore"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "BurrowStateStore",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
            ],
            path: "Sources/BurrowStateStore"
        ),
        .testTarget(
            name: "BurrowStateStoreTests",
            dependencies: ["BurrowStateStore"],
            path: "Tests/BurrowStateStoreTests"
        ),
    ]
)
