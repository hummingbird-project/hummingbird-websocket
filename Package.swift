// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-websocket",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "HummingbirdWebSocket", targets: ["HummingbirdWebSocket"]),
        // .library(name: "HummingbirdWSClient", targets: ["HummingbirdWSClient"]),
        // .library(name: "HummingbirdWSCompression", targets: ["HummingbirdWSCompression"]),
        // .library(name: "HummingbirdWSCore", targets: ["HummingbirdWSCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", branch: "2.x.x-client"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-extras/swift-extras-base64.git", from: "0.5.0"),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "HummingbirdWebSocket", dependencies: [
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTLS", package: "hummingbird"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        /* .target(name: "HummingbirdWSClient", dependencies: [
                .byName(name: "HummingbirdWSCore"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ExtrasBase64", package: "swift-extras-base64"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
            .target(name: "HummingbirdWebSocket", dependencies: [
                .byName(name: "HummingbirdWSCore"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]),
            .target(name: "HummingbirdWSCompression", dependencies: [
                .byName(name: "HummingbirdWSCore"),
                .product(name: "CompressNIO", package: "compress-nio"),
            ]),*/
        .testTarget(name: "HummingbirdWebSocketTests", dependencies: [
            .byName(name: "HummingbirdWebSocket"),
            // .byName(name: "HummingbirdWSClient"),
            // .byName(name: "HummingbirdWSCompression"),
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTLS", package: "hummingbird"),
        ]),
    ]
)
