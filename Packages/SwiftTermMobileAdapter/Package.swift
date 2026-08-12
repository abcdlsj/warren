// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BurrowSwiftTermMobileAdapter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BurrowSwiftTermMobileAdapter", targets: ["BurrowSwiftTermMobileAdapter"]),
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
            name: "BurrowSwiftTermMobileAdapter",
            dependencies: [
                .product(name: "BurrowDomain", package: "Domain"),
                .product(name: "BurrowProtocol", package: "Protocol"),
                .product(name: "BurrowClientCore", package: "ClientCore"),
                .product(name: "BurrowTerminalRenderer", package: "TerminalRenderer"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/BurrowSwiftTermMobileAdapter"
        ),
        .testTarget(
            name: "BurrowSwiftTermMobileAdapterTests",
            dependencies: ["BurrowSwiftTermMobileAdapter"],
            path: "Tests/BurrowSwiftTermMobileAdapterTests"
        ),
    ]
)
