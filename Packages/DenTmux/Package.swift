// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenTmux",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenTmux", targets: ["DenTmux"]),
    ],
    targets: [
        .target(
            name: "DenTmux",
            path: "Sources/DenTmux"
        ),
        .executableTarget(
            name: "DenTmuxTests",
            dependencies: ["DenTmux"],
            path: "Tests/DenTmuxTests"
        ),
    ]
)
