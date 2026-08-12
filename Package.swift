// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Burrow",
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
    ],
    targets: [
        .executableTarget(
            name: "BurrowNext",
            dependencies: [
                .product(name: "BurrowApplication", package: "Application"),
                .product(name: "BurrowDesktop", package: "Desktop"),
                .product(name: "BurrowTmuxRuntime", package: "TmuxRuntime"),
                .product(name: "BurrowStateStore", package: "StateStore"),
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
            ],
            path: "Sources/BurrowNext"
        ),
        .executableTarget(
            name: "UIProbe",
            dependencies: [
                .product(name: "BurrowDesktop", package: "Desktop"),
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowObservation", package: "Observation"),
            ],
            path: "Sources/UIProbe"
        ),
        .executableTarget(
            name: "TerminalProbe",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
            ],
            path: "Sources/TerminalProbe"
        ),
        .executableTarget(
            name: "ClickProbe",
            dependencies: [
                .product(name: "BurrowDesktop", package: "Desktop"),
                .product(name: "BurrowDomain", package: "Domain"),
            ],
            path: "Sources/ClickProbe"
        ),
        .executableTarget(
            name: "InputProbe",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
            ],
            path: "Sources/InputProbe"
        ),
        .executableTarget(
            name: "burrow",
            path: "Sources/burrow"
        ),
        .testTarget(
            name: "ApplicationIntegrationTests",
            dependencies: [
                .product(name: "BurrowApplication", package: "Application"),
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowStateStore", package: "StateStore"),
                .product(name: "BurrowTmuxRuntime", package: "TmuxRuntime"),
            ],
            path: "Tests/ApplicationIntegrationTests"
        ),
        .testTarget(
            name: "BurrowNextTests",
            dependencies: [
                "BurrowNext",
                .product(name: "BurrowApplication", package: "Application"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "BurrowDomain", package: "Domain"),
            ],
            path: "Tests/BurrowNextTests"
        ),
        .testTarget(
            name: "BurrowProcessTests",
            dependencies: [
                "BurrowNext",
                .product(name: "BurrowStateStore", package: "StateStore"),
            ],
            path: "Tests/BurrowProcessTests"
        ),
    ]
)
