// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowTmuxRuntime",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BurrowTmuxRuntime", targets: ["BurrowTmuxRuntime"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Host"),
    ],
    targets: [
        .target(
            name: "BurrowTmuxRuntime",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowHost", package: "Host"),
            ],
            path: "Sources/BurrowTmuxRuntime"
        ),
        .testTarget(
            name: "BurrowTmuxRuntimeTests",
            dependencies: ["BurrowTmuxRuntime"],
            path: "Tests/BurrowTmuxRuntimeTests"
        ),
    ]
)
