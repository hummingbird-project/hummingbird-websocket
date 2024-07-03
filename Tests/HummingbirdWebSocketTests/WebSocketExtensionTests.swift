//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import HummingbirdWSClient
@testable import HummingbirdWSCompression
@testable import HummingbirdWSCore
import Logging
import NIOCore
import NIOWebSocket
import ServiceLifecycle
import XCTest

final class HummingbirdWebSocketExtensionTests: XCTestCase {
    func testClientAndServer(
        serverChannel: HTTPServerBuilder,
        clientExtensions: [WebSocketExtensionFactory] = [],
        client clientHandler: @escaping WebSocketDataHandler<WebSocketClient.Context>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let serverLogger = {
                var logger = Logger(label: "WebSocketServer")
                logger.logLevel = .trace
                return logger
            }()
            let clientLogger = {
                var logger = Logger(label: "WebSocketClient")
                logger.logLevel = .trace
                return logger
            }()
            let serviceGroup: ServiceGroup
            let router = Router()
            let app = Application(
                router: router,
                server: serverChannel,
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                onServerRunning: { channel in await promise.complete(channel.localAddress!.port!) },
                logger: serverLogger
            )
            serviceGroup = ServiceGroup(
                configuration: .init(
                    services: [app],
                    gracefulShutdownSignals: [.sigterm, .sigint],
                    logger: app.logger
                )
            )
            group.addTask {
                try await serviceGroup.run()
            }
            group.addTask {
                let port = await promise.wait()
                let client = WebSocketClient(
                    url: .init("ws://localhost:\(port)/test"),
                    configuration: .init(extensions: clientExtensions),
                    logger: clientLogger,
                    handler: clientHandler
                )
                do {
                    try await client.run()
                } catch {
                    print("\(error)")
                    throw error
                }
            }
            do {
                try await group.next()
                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }

    func testClientAndServer(
        serverExtensions: [WebSocketExtensionFactory] = [],
        clientExtensions: [WebSocketExtensionFactory] = [],
        server serverHandler: @escaping WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>,
        client clientHandler: @escaping WebSocketDataHandler<WebSocketClient.Context>
    ) async throws {
        try await self.testClientAndServer(
            serverChannel: .http1WebSocketUpgrade(configuration: .init(extensions: serverExtensions)) { _, _, _ in
                .upgrade([:], serverHandler)
            },
            clientExtensions: clientExtensions,
            client: clientHandler
        )
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

    func testExtensionHeaderParsing() {
        let headers: HTTPFields = .init([
            .init(name: .secWebSocketExtensions, value: "permessage-deflate; client_max_window_bits; server_max_window_bits=10"),
            .init(name: .secWebSocketExtensions, value: "permessage-deflate;client_max_window_bits"),
        ])
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
        try await self.testClientAndServer(
            serverExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)],
            clientExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)]
        ) { inbound, _, _ in
            var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
            let firstMessage = try await iterator.next()
            XCTAssertEqual(firstMessage, .text("Hello, testing this is compressed"))
            let secondMessage = try await iterator.next()
            XCTAssertEqual(secondMessage, .text("Hello"))
        } client: { inbound, outbound, _ in
            try await outbound.write(.text("Hello, testing this is compressed"))
            try await outbound.write(.text("Hello"))
            for try await _ in inbound {}
        }
    }

    func testPerMessageDeflateMaxWindow() async throws {
        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        try await self.testClientAndServer(
            serverExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)],
            clientExtensions: [.perMessageDeflate(maxWindow: 10, minFrameSizeToCompress: 16)]
        ) { inbound, outbound, _ in
            let extensions = await outbound.handler.configuration.extensions
            XCTAssertEqual((extensions.first as? PerMessageDeflateExtension)?.configuration.receiveMaxWindow, 10)
            for try await data in inbound.messages(maxSize: .max) {
                XCTAssertEqual(data, .binary(buffer))
            }
        } client: { _, outbound, _ in
            let extensions = await outbound.handler.configuration.extensions
            XCTAssertEqual((extensions.first as? PerMessageDeflateExtension)?.configuration.sendMaxWindow, 10)
            try await outbound.write(.binary(buffer))
        }
    }

    func testPerMessageDeflateNoContextTakeover() async throws {
        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        try await self.testClientAndServer(
            serverExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)],
            clientExtensions: [.perMessageDeflate(clientNoContextTakeover: true, minFrameSizeToCompress: 16)]
        ) { inbound, outbound, _ in
            let extensions = await outbound.handler.configuration.extensions
            XCTAssertEqual((extensions.first as? PerMessageDeflateExtension)?.configuration.receiveNoContextTakeover, true)
            for try await data in inbound.messages(maxSize: .max) {
                XCTAssertEqual(data, .binary(buffer))
            }
        } client: { _, outbound, _ in
            let extensions = await outbound.handler.configuration.extensions
            XCTAssertEqual((extensions.first as? PerMessageDeflateExtension)?.configuration.sendNoContextTakeover, true)

            try await outbound.write(.binary(buffer))
        }
    }

    func testPerMessageExtensionOrdering() async throws {
        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        try await self.testClientAndServer(
            serverExtensions: [.xor(), .perMessageDeflate(serverNoContextTakeover: true, minFrameSizeToCompress: 16)],
            clientExtensions: [.xor(value: 34), .perMessageDeflate(minFrameSizeToCompress: 16)]
        ) { inbound, _, _ in
            for try await data in inbound.messages(maxSize: .max) {
                XCTAssertEqual(data, .binary(buffer))
            }
        } client: { _, outbound, _ in
            try await outbound.write(.binary(buffer))
        }
    }

    func testPerMessageDeflateWithRouter() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/test") { inbound, _, _ in
            var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
            let firstMessage = try await iterator.next()
            XCTAssertEqual(firstMessage, .text("Hello, testing this is compressed"))
            let secondMessage = try await iterator.next()
            XCTAssertEqual(secondMessage, .text("Hello"))
        }
        try await self.testClientAndServer(
            serverChannel: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ),
            clientExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)]
        ) { inbound, outbound, _ in
            try await outbound.write(.text("Hello, testing this is compressed"))
            try await outbound.write(.text("Hello"))
            for try await _ in inbound {}
        }
    }

    func testPerMessageDeflateMultiFrameMessage() async throws {
        try await self.testClientAndServer(
            serverExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)],
            clientExtensions: [.perMessageDeflate(minFrameSizeToCompress: 16)]
        ) { inbound, _, _ in
            var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
            let firstMessage = try await iterator.next()
            XCTAssertEqual(firstMessage, .text("Hello, testing this is compressed"))
        } client: { inbound, outbound, _ in
            try await outbound.withTextMessageWriter { write in
                try await write("Hello, ")
                try await write("testing this is compressed")
            }
            for try await _ in inbound {}
        }
    }

    func testCheckDeflate() async throws {
        try await self.testClientAndServer(
            serverExtensions: [.checkDeflate(), .perMessageDeflate(minFrameSizeToCompress: 16)],
            clientExtensions: [.checkDeflate(), .perMessageDeflate(minFrameSizeToCompress: 16)]
        ) { inbound, _, _ in
            var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
            let firstMessage = try await iterator.next()
            // The first message should be received
            XCTAssertEqual(firstMessage, .text("Hello, testing this is compressed"))
            // The second message will not be received because the checkDeflate extension throws
            // an error because it hasn't been compressed
            let nextMessage = try await iterator.next()
            XCTAssertEqual(nextMessage, nil)
        } client: { inbound, outbound, _ in
            try await outbound.write(.text("Hello, testing this is compressed"))
            try await outbound.write(.text("Hello"))
            for try await _ in inbound {}
        }
    }
}

/// Extension that XORs data with a specific value
struct XorWebSocketExtension: WebSocketExtension {
    let name = "xor"
    func shutdown() {}

    func xorFrame(_ frame: WebSocketFrame, context: some WebSocketContext) -> WebSocketFrame {
        var newBuffer = context.allocator.buffer(capacity: frame.data.readableBytes)
        for byte in frame.unmaskedData.readableBytesView {
            newBuffer.writeInteger(byte ^ self.value)
        }
        var frame = frame
        frame.data = newBuffer
        frame.maskKey = nil
        return frame
    }

    func processReceivedFrame(_ frame: WebSocketFrame, context: some WebSocketContext) -> WebSocketFrame {
        return self.xorFrame(frame, context: context)
    }

    func processFrameToSend(_ frame: WebSocketFrame, context: some WebSocketContext) throws -> WebSocketFrame {
        return self.xorFrame(frame, context: context)
    }

    let value: UInt8
}

struct XorWebSocketExtensionBuilder: WebSocketExtensionBuilder {
    static var name = "permessage-xor"
    let value: UInt8?

    init(value: UInt8? = nil) {
        self.value = value
    }

    func clientRequestHeader() -> String {
        var header = Self.name
        if let value {
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

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }
}

extension WebSocketExtensionFactory {
    static func xor(value: UInt8? = nil) -> WebSocketExtensionFactory {
        .init { XorWebSocketExtensionBuilder(value: value) }
    }
}

/// Extension that checks whether frames coming in have been compressed
struct CheckDeflateWebSocketExtension: WebSocketExtension {
    struct NoDeflateError: Error {}
    let name = "check-deflate"
    func shutdown() {}

    func processReceivedFrame(_ frame: WebSocketFrame, context: some WebSocketContext) throws -> WebSocketFrame {
        guard frame.rsv1 else { throw NoDeflateError() }
        return frame
    }

    func processFrameToSend(_ frame: WebSocketFrame, context: some WebSocketContext) throws -> WebSocketFrame {
        return frame
    }
}

struct CheckDeflateWebSocketExtensionBuilder: WebSocketExtensionBuilder {
    static var name = "check-deflate"

    func clientRequestHeader() -> String {
        return Self.name
    }

    func serverReponseHeader(to request: WebSocketExtensionHTTPParameters) -> String? {
        return Self.name
    }

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        CheckDeflateWebSocketExtension()
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        CheckDeflateWebSocketExtension()
    }
}

extension WebSocketExtensionFactory {
    static func checkDeflate() -> WebSocketExtensionFactory {
        .init { CheckDeflateWebSocketExtensionBuilder() }
    }
}
