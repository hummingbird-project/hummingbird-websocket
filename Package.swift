// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-websocket",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(name: "HummingbirdWebSocket", targets: ["HummingbirdWebSocket"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird-core.git", from: "0.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.20.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(name: "HummingbirdWebSocket", dependencies: [
            .product(name: "HummingbirdCore", package: "hummingbird-core"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .testTarget(name: "HummingbirdWebSocketTests", dependencies: ["HummingbirdWebSocket"]),
    ]
)
