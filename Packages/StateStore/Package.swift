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
        .package(path: "../ClientCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.8.0"),
    ],
    targets: [
        .target(
            name: "BurrowStateStore",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/BurrowStateStore"
        ),
        .testTarget(
            name: "BurrowStateStoreTests",
            dependencies: [
                "BurrowStateStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/BurrowStateStoreTests"
        ),
    ]
)
