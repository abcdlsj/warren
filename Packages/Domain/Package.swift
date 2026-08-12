// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowDomain",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BurrowDomain", targets: ["BurrowDomain"]),
    ],
    targets: [
        .target(
            name: "BurrowDomain",
            path: "Sources/BurrowDomain"
        ),
        .testTarget(
            name: "BurrowDomainTests",
            dependencies: ["BurrowDomain"],
            path: "Tests/BurrowDomainTests"
        ),
    ]
)
