//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
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
@testable import HummingbirdWebSocket
@testable import HummingbirdWSCompression
import Logging
import NIOCore
import NIOWebSocket
import ServiceLifecycle
import XCTest

final class HummingbirdWebSocketExtensionTests: XCTestCase {
    func testClientAndServer(
        serverExtensions: [WebSocketExtensionFactory] = [],
        clientExtensions: [WebSocketExtensionFactory] = [],
        server serverHandler: @escaping WebSocketDataHandler<BasicWebSocketRequestContext>,
        client clientHandler: @escaping WebSocketDataHandler<WebSocketContext>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let serverLogger = {
                var logger = Logger(label: "WebSocketServer")
                logger.logLevel = .debug
                return logger
            }()
            let clientLogger = {
                var logger = Logger(label: "WebSocketClient")
                logger.logLevel = .debug
                return logger
            }()
            let router = Router(context: BasicWebSocketRequestContext.self)
            router.ws("/test", onUpgrade: serverHandler)
            let serviceGroup: ServiceGroup
            let app = Application(
                router: router,
                server: .webSocketUpgrade(webSocketRouter: router, configuration: .init(extensions: serverExtensions)),
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
                let client = try WebSocketClient(
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
            serverExtensions: [.perMessageDeflate()],
            clientExtensions: [.perMessageDeflate()]
        ) { inbound, _, _ in
            var iterator = inbound.makeAsyncIterator()
            let firstMessage = await iterator.next()
            XCTAssertEqual(firstMessage, .text("Hello, testing this is compressed"))
            let secondMessage = await iterator.next()
            XCTAssertEqual(secondMessage, .text("Hello"))
        } client: { inbound, outbound, _ in
            try await outbound.write(.text("Hello, testing this is compressed"))
            try await outbound.write(.text("Hello"))
            for try await _ in inbound {}
        }
        /*    onServer: { ws in
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
         )*/
    }

    /*     static var eventLoopGroup: EventLoopGroup!

     override class func setUp() {
         self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
     }

     override class func tearDown() {
         XCTAssertNoThrow(try self.eventLoopGroup.syncShutdownGracefully())
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
         serverExtensions: [WebSocketExtensionFactory] = [],
         clientExtensions: [WebSocketExtensionFactory] = [],
         onServer: @escaping (WebSocket) async throws -> Void,
         onClient: @escaping (WebSocket) async throws -> Void
     ) async throws -> HBApplication {
         let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
         app.logger.logLevel = .trace
         // add HTTP to WebSocket upgrade
         app.ws.addUpgrade(maxFrameSize: 1 << 14, extensions: serverExtensions)
         // on websocket connect.
         app.ws.on("/test", onUpgrade: { _, ws in
             try await onServer(ws)
             return .ok
         })
         try app.start()

         let eventLoop = app.eventLoopGroup.next()
         let ws = try await WebSocketClient.connect(
             url: HBURL("ws://localhost:\(app.server.port!)/test"),
             configuration: .init(extensions: clientExtensions),
             on: eventLoop
         )
         try await onClient(ws)
         return app
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
     }*/
}

struct XorWebSocketExtension: WebSocketExtension {
    func shutdown() {}

    func xorFrame(_ frame: WebSocketFrame, context: some WebSocketContextProtocol) -> WebSocketFrame {
        var newBuffer = context.allocator.buffer(capacity: frame.data.readableBytes)
        for byte in frame.data.readableBytesView {
            newBuffer.writeInteger(byte ^ self.value)
        }
        var frame = frame
        frame.data = newBuffer
        return frame
    }

    func processReceivedFrame(_ frame: WebSocketFrame, context: some WebSocketContextProtocol) -> WebSocketFrame {
        return self.xorFrame(frame, context: context)
    }

    func processFrameToSend(_ frame: WebSocketFrame, context: some WebSocketContextProtocol) throws -> WebSocketFrame {
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

    func serverExtension(from request: WebSocketExtensionHTTPParameters, eventLoop: EventLoop) throws -> (WebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters, eventLoop: EventLoop) throws -> (WebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }
}

extension WebSocketExtensionFactory {
    static func xor(value: UInt8? = nil) -> WebSocketExtensionFactory {
        .init { XorWebSocketExtensionBuilder(value: value) }
    }
}
