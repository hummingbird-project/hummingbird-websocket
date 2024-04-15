// swift-tools-version:5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-websocket",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "HummingbirdWebSocket", targets: ["HummingbirdWebSocket"]),
        .library(name: "HummingbirdWSClient", targets: ["HummingbirdWSClient"]),
        .library(name: "HummingbirdWSCompression", targets: ["HummingbirdWSCompression"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0-beta.2"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "HummingbirdWebSocket", dependencies: [
            .byName(name: "HummingbirdWSCore"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
            .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
        ]),
        .target(name: "HummingbirdWSClient", dependencies: [
            .byName(name: "HummingbirdWSCore"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .target(name: "HummingbirdWSCore", dependencies: [
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),
        .target(name: "HummingbirdWSCompression", dependencies: [
            .byName(name: "HummingbirdWSCore"),
            .product(name: "CompressNIO", package: "compress-nio"),
        ]),
        .testTarget(name: "HummingbirdWebSocketTests", dependencies: [
            .byName(name: "HummingbirdWebSocket"),
            .byName(name: "HummingbirdWSClient"),
            .byName(name: "HummingbirdWSCompression"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "HummingbirdTLS", package: "hummingbird"),
        ]),
    ]
)
