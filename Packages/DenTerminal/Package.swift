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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "DenTerminal",
            dependencies: ["SwiftTerm"],
            path: "Sources/DenTerminal"
        ),
    ]
)
