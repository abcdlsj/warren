// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowObservation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BurrowObservation", targets: ["BurrowObservation"]),
    ],
    targets: [
        .target(
            name: "BurrowObservation",
            path: "Sources/BurrowObservation"
        ),
        .testTarget(
            name: "BurrowObservationTests",
            dependencies: ["BurrowObservation"],
            path: "Tests/BurrowObservationTests"
        ),
    ]
)
