// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var swiftSettings: [SwiftSetting] = [
    // https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
    .enableUpcomingFeature("ExistentialAny"),

    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
    .enableUpcomingFeature("MemberImportVisibility"),

    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
    .enableUpcomingFeature("InternalImportsByDefault"),
]

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
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.24.0", traits: []),
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.1"),
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
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HummingbirdWSClient",
            dependencies: [
                .product(name: "WSClient", package: "swift-websocket")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HummingbirdWSCompression",
            dependencies: [
                .product(name: "WSCompression", package: "swift-websocket")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HummingbirdWSTesting",
            dependencies: [
                .byName(name: "HummingbirdWSClient"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: swiftSettings
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
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
