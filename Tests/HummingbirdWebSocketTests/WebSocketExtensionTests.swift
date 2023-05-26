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
import NIOWebSocket
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
        serverExtensions: [HBWebSocketExtensionFactory] = [],
        clientExtensions: [HBWebSocketExtensionFactory] = [],
        onServer: @escaping (HBWebSocket) async throws -> Void,
        onClient: @escaping (HBWebSocket) async throws -> Void
    ) async throws -> HBApplication {
        let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
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
            url: HBURL("ws://localhost:\(app.server.port!)/test"),
            configuration: .init(extensions: clientExtensions),
            on: eventLoop
        )
        try await onClient(ws)
        return app
    }

    func testExtensionHeaderParsing() {
        let headers: HTTPHeaders = ["Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits; server_max_window_bits=10, permessage-deflate;client_max_window_bits"]
        let extensions = WebSocketExtensionHTTPParameters.parseHeaders(headers)
        XCTAssertEqual(
            extensions,
            [
                .init("permessage-deflate", parameters: ["client_max_window_bits": .null, "server_max_window_bits": .value("10")]),
                .init("permessage-deflate", parameters: ["client_max_window_bits": .null]),
            ]
        )
    }

    func testDeflateServerResponse() {
        let requestHeaders: [WebSocketExtensionHTTPParameters] = [
            .init("permessage-deflate", parameters: ["client_max_window_bits": .value("10")]),
        ]
        let ext = PerMessageDeflateExtensionBuilder(clientNoContextTakeover: true, serverNoContextTakeover: true)
        let serverResponse = ext.serverResponseHeader(to: requestHeaders)
        XCTAssertEqual(
            serverResponse,
            "permessage-deflate;client_max_window_bits=10;client_no_context_takeover;server_no_context_takeover"
        )
    }

    func testDeflateServerResponseClientMaxWindowBits() {
        let requestHeaders: [WebSocketExtensionHTTPParameters] = [
            .init("permessage-deflate", parameters: ["client_max_window_bits": .null]),
        ]
        let ext1 = PerMessageDeflateExtensionBuilder(serverNoContextTakeover: true)
        let serverResponse1 = ext1.serverResponseHeader(to: requestHeaders)
        XCTAssertEqual(
            serverResponse1,
            "permessage-deflate;server_no_context_takeover"
        )
        let ext2 = PerMessageDeflateExtensionBuilder(clientNoContextTakeover: true, serverMaxWindow: 12)
        let serverResponse2 = ext2.serverResponseHeader(to: requestHeaders)
        XCTAssertEqual(
            serverResponse2,
            "permessage-deflate;client_no_context_takeover;server_max_window_bits=12"
        )
    }

    func testUnregonisedExtensionServerResponse() {
        let requestHeaders: [WebSocketExtensionHTTPParameters] = [
            .init("permessage-foo", parameters: ["bar": .value("baz")]),
            .init("permessage-deflate", parameters: ["client_max_window_bits": .value("10")]),
        ]
        let ext = PerMessageDeflateExtensionBuilder()
        let serverResponse = ext.serverResponseHeader(to: requestHeaders)
        XCTAssertEqual(
            serverResponse,
            "permessage-deflate;client_max_window_bits=10"
        )
    }

    func testPerMessageDeflate() async throws {
        let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

        let app = try await self.setupClientAndServer(
            serverExtensions: [.perMessageDeflate()],
            clientExtensions: [.perMessageDeflate()],
            onServer: { ws in
                XCTAssertNotNil(ws.extensions.first as? PerMessageDeflateExtension)
                let stream = ws.readStream()
                Task {
                    var iterator = stream.makeAsyncIterator()
                    let firstMessage = await iterator.next()
                    XCTAssertEqual(firstMessage, .text("Hello, testing this is compressed"))
                    let secondMessage = await iterator.next()
                    XCTAssertEqual(secondMessage, .text("Hello"))
                    for await _ in stream {}
                    ws.onClose { _ in
                        promise.succeed()
                    }
                }
            },
            onClient: { ws in
                XCTAssertNotNil(ws.extensions.first as? PerMessageDeflateExtension)
                try await ws.write(.text("Hello, testing this is compressed"))
                try await ws.write(.text("Hello"))
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
            serverExtensions: [.perMessageDeflate()],
            clientExtensions: [.perMessageDeflate(maxWindow: 10)],
            onServer: { ws in
                XCTAssertEqual((ws.extensions.first as? PerMessageDeflateExtension)?.configuration.receiveMaxWindow, 10)
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
                XCTAssertEqual((ws.extensions.first as? PerMessageDeflateExtension)?.configuration.sendMaxWindow, 10)
                try await ws.write(.binary(buffer))
                try await ws.close()
            }
        )
        defer { app.stop() }

        try promise.wait()
    }

    func testPerMessageDeflateNoContextTakeover() async throws {
        let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        let app = try await self.setupClientAndServer(
            serverExtensions: [.perMessageDeflate()],
            clientExtensions: [.perMessageDeflate(clientNoContextTakeover: true)],
            onServer: { ws in
                XCTAssertEqual((ws.extensions.first as? PerMessageDeflateExtension)?.configuration.receiveNoContextTakeover, true)
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
                XCTAssertEqual((ws.extensions.first as? PerMessageDeflateExtension)?.configuration.sendNoContextTakeover, true)
                try await ws.write(.binary(buffer))
                try await ws.close()
            }
        )
        defer { app.stop() }

        try promise.wait()
    }

    func testPerMessageExtensionOrdering() async throws {
        let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        let app = try await self.setupClientAndServer(
            serverExtensions: [.xor(), .perMessageDeflate()],
            clientExtensions: [.xor(value: 34), .perMessageDeflate()],
            onServer: { ws in
                // XCTAssertEqual((ws.extensions.first as? PerMessageDeflateExtension)?.configuration.receiveNoContextTakeover, true)
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
                // XCTAssertEqual((ws.extensions.first as? PerMessageDeflateExtension)?.configuration.sendNoContextTakeover, true)
                try await ws.write(.binary(buffer))
                try await ws.close()
            }
        )
        defer { app.stop() }

        try promise.wait()
    }
}

struct XorWebSocketExtension: HBWebSocketExtension {
    func xorFrame(_ frame: WebSocketFrame, ws: HBWebSocket) -> WebSocketFrame {
        var newBuffer = ws.channel.allocator.buffer(capacity: frame.data.readableBytes)
        for byte in frame.data.readableBytesView {
            newBuffer.writeInteger(byte ^ self.value)
        }
        var frame = frame
        frame.data = newBuffer
        return frame
    }

    func processReceivedFrame(_ frame: WebSocketFrame, ws: HBWebSocket) -> WebSocketFrame {
        return self.xorFrame(frame, ws: ws)
    }

    func processFrameToSend(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame {
        return self.xorFrame(frame, ws: ws)
    }

    let value: UInt8
}

struct XorWebSocketExtensionBuilder: HBWebSocketExtensionBuilder {
    static var name = "permessage-xor"
    let value: UInt8?

    init(value: UInt8? = nil) {
        self.value = value
    }

    func clientRequestHeader() -> String {
        var header = Self.name
        if let value = value {
            header += ";value=\(value)"
        }
        return header
    }

    func serverReponseHeader(to request: WebSocketExtensionHTTPParameters) -> String? {
        var header = Self.name
        if let value = request.parameters["value"]?.integer {
            header += ";value=\(value)"
        }
        return header
    }

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (HBWebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (HBWebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }
}

extension HBWebSocketExtensionFactory {
    static func xor(value: UInt8? = nil) -> HBWebSocketExtensionFactory {
        .init { XorWebSocketExtensionBuilder(value: value) }
    }
}
