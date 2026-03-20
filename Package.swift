// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Den",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Packages/DenCore"),
        .package(path: "Packages/DenPersistence"),
        .package(path: "Packages/DenTmux"),
        .package(path: "Packages/DenGit"),
        .package(path: "Packages/DenTerminal"),
        .package(path: "Packages/DenUI"),
    ],
    targets: [
        .executableTarget(
            name: "Den",
            dependencies: [
                "DenCore",
                "DenPersistence",
                "DenTmux",
                "DenGit",
                "DenTerminal",
                "DenUI",
            ],
            path: "Sources/Den"
        ),
    ]
)
