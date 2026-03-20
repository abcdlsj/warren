// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenPersistence",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenPersistence", targets: ["DenPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../DenCore"),
    ],
    targets: [
        .target(
            name: "DenPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "DenCore",
            ],
            path: "Sources/DenPersistence"
        ),
    ]
)
