// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Packages/Legacy/Config"),
        .package(path: "Packages/Legacy/Core"),
        .package(path: "Packages/Legacy/Persistence"),
        .package(path: "Packages/Legacy/Tmux"),
        .package(path: "Packages/Legacy/Git"),
        .package(path: "Packages/Legacy/Terminal"),
        .package(path: "Packages/Legacy/UI"),
        .package(path: "Packages/Desktop"),
        .package(path: "Packages/GhosttyAdapter"),
        .package(path: "Packages/WebRelay"),
        .package(path: "Packages/Application"),
        .package(path: "Packages/TmuxRuntime"),
        .package(path: "Packages/StateStore"),
        .package(path: "Packages/Domain"),
        .package(path: "Packages/ClientCore"),
        .package(path: "Packages/Protocol"),
    ],
    targets: [
        .executableTarget(
            name: "Den",
            dependencies: [
                .product(name: "DenConfig", package: "Config"),
                .product(name: "DenCore", package: "Core"),
                .product(name: "DenPersistence", package: "Persistence"),
                .product(name: "DenTmux", package: "Tmux"),
                .product(name: "DenGit", package: "Git"),
                .product(name: "DenTerminal", package: "Terminal"),
                .product(name: "DenUI", package: "UI"),
            ],
            path: "Sources/Den"
        ),
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
                .product(name: "WebRelay", package: "WebRelay"),
            ],
            path: "Sources/BurrowNext"
        ),
        .executableTarget(
            name: "UIProbe",
            dependencies: [
                .product(name: "BurrowDesktop", package: "Desktop"),
                .product(name: "BurrowDomain", package: "Domain"),
            ],
            path: "Sources/UIProbe"
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
    ]
)
