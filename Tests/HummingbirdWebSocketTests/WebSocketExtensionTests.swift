//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
@testable import HummingbirdWSCore
import NIOCore
import NIOPosix
import XCTest

final class HummingbirdWebSocketExtensionTests: XCTestCase {
    static var eventLoopGroup: EventLoopGroup!

    override class func setUp() {
        Self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override class func tearDown() {
        XCTAssertNoThrow(try Self.eventLoopGroup.syncShutdownGracefully())
    }

    /// Create random buffer
    /// - Parameters:
    ///   - size: size of buffer
    ///   - randomness: how random you want the buffer to be (percentage)
    func createRandomBuffer(size: Int, randomness: Int = 100) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        let randomness = (randomness * randomness) / 100
        for i in 0..<size {
            let random = Int.random(in: 0..<25600)
            if random < randomness * 256 {
                buffer.writeInteger(UInt8(random & 0xFF))
            } else {
                buffer.writeInteger(UInt8(i & 0xFF))
            }
        }
        return buffer
    }

    func setupClientAndServer(
        serverExtensions: [WebSocketExtensionConfig] = [],
        clientExtensions: [WebSocketExtensionConfig] = [],
        onServer: @escaping (HBWebSocket) async throws -> Void,
        onClient: @escaping (HBWebSocket) async throws -> Void
    ) async throws -> HBApplication {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
        // add HTTP to WebSocket upgrade
        app.ws.addUpgrade(maxFrameSize: 1 << 14, extensions: serverExtensions)
        // on websocket connect.
        app.ws.on("/test", onUpgrade: { _, ws in
            try await onServer(ws)
            return .ok
        })
        try app.start()

        let eventLoop = app.eventLoopGroup.next()
        let ws = try await HBWebSocketClient.connect(
            url: "ws://localhost:8080/test",
            configuration: .init(extensions: clientExtensions),
            on: eventLoop
        )
        try await onClient(ws)
        return app
    }

    func testExtensionHeaderParsing() {
        let headers: HTTPHeaders = ["Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits; server_max_window_bits=10, permessage-deflate;client_max_window_bits"]
        let extensions = WebSocketExtensionHTTPParameters.parseHeaders(headers, type: .server)
        XCTAssertEqual(
            extensions,
            [
                .perMessageDeflate(maxWindow: 10, noContextTakeover: false, supportsMaxWindow: true, supportsNoContextTakeover: false),
                .perMessageDeflate(maxWindow: nil, noContextTakeover: false, supportsMaxWindow: true, supportsNoContextTakeover: false),
            ]
        )
    }

    func testExtensionResponse() {
        let requestExt: [WebSocketExtensionHTTPParameters] = [
            .perMessageDeflate(maxWindow: 10, noContextTakeover: false, supportsMaxWindow: false, supportsNoContextTakeover: true),
            .perMessageDeflate(maxWindow: nil, noContextTakeover: false, supportsMaxWindow: false, supportsNoContextTakeover: false),
        ]
        let ext = WebSocketExtensionConfig.perMessageDeflate(maxWindow: nil, noContextTakeover: true)
        XCTAssertEqual(
            [ext].respond(to: requestExt),
            [.perMessageDeflate(requestMaxWindow: 10, requestNoContextTakeover: true, responseMaxWindow: nil, responseNoContextTakeover: true)]
        )
    }

    func testPerMessageDeflate() async throws {
        let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

        let app = try await self.setupClientAndServer(
            serverExtensions: [.perMessageDeflate(noContextTakeover: true)],
            clientExtensions: [.perMessageDeflate(noContextTakeover: true)],
            onServer: { ws in
                XCTAssertTrue(ws.extensions.count > 0)
                let stream = ws.readStream()
                Task {
                    for try await data in stream {
                        XCTAssertEqual(data, .text("Hello, testing this is compressed"))
                    }
                    ws.onClose { _ in
                        promise.succeed()
                    }
                }
            },
            onClient: { ws in
                XCTAssertTrue(ws.extensions.count > 0)
                try await ws.write(.text("Hello, testing this is compressed"))
                try await ws.close()
            }
        )
        defer { app.stop() }

        try promise.wait()
    }

    func testPerMessageDeflateMaxWindow() async throws {
        let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        let app = try await self.setupClientAndServer(
            serverExtensions: [.perMessageDeflate(noContextTakeover: true)],
            clientExtensions: [.perMessageDeflate(maxWindow: 10, noContextTakeover: true)],
            onServer: { ws in
                XCTAssertTrue(ws.extensions.count > 0)
                let stream = ws.readStream()
                Task {
                    for try await data in stream {
                        XCTAssertEqual(data, .binary(buffer))
                    }
                    ws.onClose { _ in
                        promise.succeed()
                    }
                }
            },
            onClient: { ws in
                XCTAssertTrue(ws.extensions.count > 0)
                try await ws.write(.binary(buffer))
                try await ws.close()
            }
        )
        defer { app.stop() }

        try promise.wait()
    }
}
