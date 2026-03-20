// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenGit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenGit", targets: ["DenGit"]),
    ],
    targets: [
        .target(
            name: "DenGit",
            path: "Sources/DenGit"
        ),
        .executableTarget(
            name: "DenGitTests",
            dependencies: ["DenGit"],
            path: "Tests/DenGitTests"
        ),
    ]
)
