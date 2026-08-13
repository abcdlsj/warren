// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenSwiftTermMobileAdapter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WarrenSwiftTermMobileAdapter", targets: ["WarrenSwiftTermMobileAdapter"]),
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
            name: "WarrenSwiftTermMobileAdapter",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenTerminalRenderer", package: "TerminalRenderer"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/WarrenSwiftTermMobileAdapter"
        ),
        .testTarget(
            name: "WarrenSwiftTermMobileAdapterTests",
            dependencies: ["WarrenSwiftTermMobileAdapter"],
            path: "Tests/WarrenSwiftTermMobileAdapterTests"
        ),
    ]
)
