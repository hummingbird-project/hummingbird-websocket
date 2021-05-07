// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-websocket",
    platforms: [.iOS(.v12), .tvOS(.v12)],
    products: [
        .library(name: "HummingbirdWebSocket", targets: ["HummingbirdWebSocket"]),
        .library(name: "HummingbirdWSClient", targets: ["HummingbirdWSClient"]),
        .library(name: "HummingbirdWSCore", targets: ["HummingbirdWSCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird-core.git", from: "0.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.20.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-extras/swift-extras-base64.git", from: "0.5.0"),
    ],
    targets: [
        .target(name: "HummingbirdWSCore", dependencies: [
            .product(name: "HummingbirdCore", package: "hummingbird-core"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .target(name: "HummingbirdWSClient", dependencies: [
            .byName(name: "HummingbirdWSCore"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "ExtrasBase64", package: "swift-extras-base64"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "HummingbirdWebSocket", dependencies: [
            .byName(name: "HummingbirdWSCore"),
            .product(name: "Hummingbird", package: "hummingbird"),
        ]),
        .testTarget(name: "HummingbirdWebSocketTests", dependencies: [
            .byName(name: "HummingbirdWebSocket"),
            .byName(name: "HummingbirdWSClient"),
        ]),
    ]
)
