// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-websocket",
    products: [
        .library(name: "HummingbirdWebSocket", targets: ["HummingbirdWebSocket"]),
        .library(name: "HummingbirdWSCore", targets: ["HummingbirdWSCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird-core.git", from: "0.3.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "0.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.20.0"),
        // used in tests
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "HummingbirdWSCore", dependencies: [
            .product(name: "HummingbirdCore", package: "hummingbird-core"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .target(name: "HummingbirdWebSocket", dependencies: [
            .byName(name: "HummingbirdWSCore"),
            .product(name: "Hummingbird", package: "hummingbird"),
        ]),
        .testTarget(name: "HummingbirdWebSocketTests", dependencies: [
            .byName(name: "HummingbirdWebSocket"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ]),
    ]
)
