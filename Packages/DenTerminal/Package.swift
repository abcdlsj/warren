// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DenTerminal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DenTerminal", targets: ["DenTerminal"]),
    ],
    targets: [
        .target(
            name: "DenTerminal",
            dependencies: ["GhosttyKit"],
            path: "Sources/DenTerminal",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../Frameworks/GhosttyKit.xcframework"
        ),
    ]
)
