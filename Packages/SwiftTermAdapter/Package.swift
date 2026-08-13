// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenSwiftTermAdapter",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WarrenSwiftTermAdapter", targets: ["WarrenSwiftTermAdapter"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../ClientCore"),
        .package(path: "../TerminalRenderer"),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.2.0"
        ),
    ],
    targets: [
        .target(
            name: "WarrenSwiftTermAdapter",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenTerminalRenderer", package: "TerminalRenderer"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/WarrenSwiftTermAdapter"
        ),
        .testTarget(
            name: "WarrenSwiftTermAdapterTests",
            dependencies: ["WarrenSwiftTermAdapter"],
            path: "Tests/WarrenSwiftTermAdapterTests"
        ),
    ]
)
