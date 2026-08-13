// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Warren",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Packages/Desktop"),
        .package(path: "Packages/GhosttyAdapter"),
        .package(path: "Packages/Application"),
        .package(path: "Packages/TmuxRuntime"),
        .package(path: "Packages/StateStore"),
        .package(path: "Packages/Domain"),
        .package(path: "Packages/ClientCore"),
        .package(path: "Packages/Protocol"),
        .package(path: "Packages/Observation"),
        .package(path: "Packages/WebRelay"),
    ],
    targets: [
        .executableTarget(
            name: "WarrenNext",
            dependencies: [
                .product(name: "WarrenApplication", package: "Application"),
                .product(name: "WarrenDesktop", package: "Desktop"),
                .product(name: "WarrenTmuxRuntime", package: "TmuxRuntime"),
                .product(name: "WarrenStateStore", package: "StateStore"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
                .product(name: "WebRelay", package: "WebRelay"),
            ],
            path: "Sources/WarrenNext"
        ),
        .executableTarget(
            name: "UIProbe",
            dependencies: [
                .product(name: "WarrenDesktop", package: "Desktop"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenObservation", package: "Observation"),
            ],
            path: "Sources/UIProbe"
        ),
        .executableTarget(
            name: "TerminalProbe",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
            ],
            path: "Sources/TerminalProbe"
        ),
        .executableTarget(
            name: "warren",
            path: "Sources/warren"
        ),
        .testTarget(
            name: "ApplicationIntegrationTests",
            dependencies: [
                .product(name: "WarrenApplication", package: "Application"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenStateStore", package: "StateStore"),
                .product(name: "WarrenTmuxRuntime", package: "TmuxRuntime"),
            ],
            path: "Tests/ApplicationIntegrationTests"
        ),
        .testTarget(
            name: "WarrenNextTests",
            dependencies: [
                "WarrenNext",
                .product(name: "WarrenApplication", package: "Application"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenDomain", package: "Domain"),
            ],
            path: "Tests/WarrenNextTests"
        ),
        .testTarget(
            name: "WarrenProcessTests",
            dependencies: [
                "WarrenNext",
                .product(name: "WarrenStateStore", package: "StateStore"),
            ],
            path: "Tests/WarrenProcessTests"
        ),
    ]
)
