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
        .library(name: "HummingbirdWSTesting", targets: ["HummingbirdWSTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.14.0"),
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.5.0"),
    ],
    targets: [
        .target(
            name: "HummingbirdWebSocket",
            dependencies: [
                .product(name: "WSCore", package: "swift-websocket"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
            ]
        ),
        .target(
            name: "HummingbirdWSClient",
            dependencies: [
                .product(name: "WSClient", package: "swift-websocket")
            ]
        ),
        .target(
            name: "HummingbirdWSCompression",
            dependencies: [
                .product(name: "WSCompression", package: "swift-websocket")
            ]
        ),
        .target(
            name: "HummingbirdWSTesting",
            dependencies: [
                .byName(name: "HummingbirdWSClient"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "HummingbirdWebSocketTests",
            dependencies: [
                .byName(name: "HummingbirdWebSocket"),
                .byName(name: "HummingbirdWSClient"),
                .byName(name: "HummingbirdWSCompression"),
                .byName(name: "HummingbirdWSTesting"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5, .version("6")]
)
