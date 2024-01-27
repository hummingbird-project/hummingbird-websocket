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
import HummingbirdTLS
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import ServiceLifecycle
import XCTest

/// Promise type.
actor Promise<Value> {
    enum State {
        case blocked([CheckedContinuation<Value, Never>])
        case unblocked(Value)
    }

    var state: State

    init() {
        self.state = .blocked([])
    }

    /// wait from promise to be completed
    func wait() async -> Value {
        switch self.state {
        case .blocked(var continuations):
            return await withCheckedContinuation { cont in
                continuations.append(cont)
                self.state = .blocked(continuations)
            }
        case .unblocked(let value):
            return value
        }
    }

    /// complete promise with value
    func complete(_ value: Value) {
        switch self.state {
        case .blocked(let continuations):
            for cont in continuations {
                cont.resume(returning: value)
            }
            self.state = .unblocked(value)
        case .unblocked:
            break
        }
    }
}

final class HummingbirdWebSocketTests: XCTestCase {
    func createRandomBuffer(size: Int) -> ByteBuffer {
         // create buffer
         var data = [UInt8](repeating: 0, count: size)
         for i in 0..<size {
             data[i] = UInt8.random(in: 0...255)
         }
         return ByteBuffer(bytes: data)
    }

    func testClientAndServer(
        serverTLSConfiguration: TLSConfiguration? = nil, 
        server serverHandler: @escaping HBWebSocketDataCallbackHandler.Callback,
        shouldUpgrade: @escaping @Sendable (HTTPRequestHead) throws -> HTTPHeaders? = { _ in return [:] },
        getClient: @escaping @Sendable (Int, Logger) throws -> HBWebSocketClient<some HBWebSocketDataHandler>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let logger = {
                var logger = Logger(label: "WebSocketTest")
                logger.logLevel = .debug
                return logger
            }()
            let router = HBRouter()
            let serviceGroup: ServiceGroup
            let webSocketUpgrade: HBHTTPChannelBuilder<some HTTPChannelHandler> = .webSocketUpgrade { _,head in
                if let headers = try shouldUpgrade(head) {
                    return .upgrade(headers, HBWebSocketDataCallbackHandler(serverHandler))
                } else {
                    return .dontUpgrade
                }
            }
            if let serverTLSConfiguration {
                let app = try HBApplication(
                    router: router,
                    server: .tls(webSocketUpgrade, tlsConfiguration: serverTLSConfiguration),
                    onServerRunning: { channel in await promise.complete(channel.localAddress!.port!)},
                    logger: logger
                )
                serviceGroup = ServiceGroup(
                    configuration: .init(
                        services: [app],
                        gracefulShutdownSignals: [.sigterm, .sigint],
                        logger: app.logger
                    )
                )
            } else {
                let app = HBApplication(
                    router: router,
                    server: webSocketUpgrade,
                    onServerRunning: { channel in await promise.complete(channel.localAddress!.port!)},
                    logger: logger
                )
                serviceGroup = ServiceGroup(
                    configuration: .init(
                        services: [app],
                        gracefulShutdownSignals: [.sigterm, .sigint],
                        logger: app.logger
                    )
                )
            }
            group.addTask {
                try await serviceGroup.run()
            }
            group.addTask {
                let client = try await getClient(promise.wait(), logger)
                do {
                    try await client.run()
                } catch {
                    throw error
                }
            }
            try await group.next()
            await serviceGroup.triggerGracefulShutdown()
        }
    }

    func testClientAndServer(
        serverTLSConfiguration: TLSConfiguration? = nil, 
        server serverHandler: @escaping HBWebSocketDataCallbackHandler.Callback,
        shouldUpgrade: @escaping @Sendable (HTTPRequestHead) throws -> HTTPHeaders? = { _ in return [:] },
        client clientHandler: @escaping HBWebSocketDataCallbackHandler.Callback
    ) async throws {
        try await testClientAndServer(
            serverTLSConfiguration: serverTLSConfiguration,
            server: serverHandler, 
            shouldUpgrade: shouldUpgrade, 
            getClient: { port, logger in
                try HBWebSocketClient(
                    url: .init("ws://localhost:\(port)"), 
                    logger: logger,
                    handlerCallback: clientHandler
                )
            }
        )
    }

    func testServerToClientMessage() async throws {
        try await testClientAndServer { inbound, outbound, context in
            try await outbound.write(.text("Hello"))
        } client: { inbound, outbound, context in
            var inboundIterator = inbound.makeAsyncIterator()
            let msg = await inboundIterator.next()
            XCTAssertEqual(msg, .text("Hello"))
        }
    }

    func testClientToServerMessage() async throws {
        try await testClientAndServer { inbound, outbound, context in
            var inboundIterator = inbound.makeAsyncIterator()
            let msg = await inboundIterator.next()
            XCTAssertEqual(msg, .text("Hello"))
        } client: { inbound, outbound, context in
            try await outbound.write(.text("Hello"))
        }
    }

    func testClientToServerSplitPacket() async throws {
        try await testClientAndServer { inbound, outbound, context in
            for try await packet in inbound {
                try await outbound.write(.custom(packet.webSocketFrame))
            }
        } client: { inbound, outbound, context in
            let buffer = ByteBuffer(string: "Hello ")
            try await outbound.write(.custom(.init(fin: false, opcode: .text, data: buffer)))
            let buffer2 = ByteBuffer(string: "World!")
            try await outbound.write(.custom(.init(fin: true, opcode: .text, data: buffer2)))

            var inboundIterator = inbound.makeAsyncIterator()
            let msg = await inboundIterator.next()
            XCTAssertEqual(msg, .text("Hello World!"))
        }
    }

    // test connection is closed when buffer is too large
    func testTooLargeBuffer() async throws {
        try await testClientAndServer { inbound, outbound, context in
            let buffer = ByteBuffer(repeating: 1, count: (1 << 14) + 1 )
            try await outbound.write(.binary(buffer))
            for try await _ in inbound {}
        } client: { inbound, outbound, context in
            for try await _ in inbound {}
        }        
    }

    func testNotWebSocket() async throws {
        // currently disabled as NIO websocket code doesnt shutdown correctly here
        try XCTSkipIf(true)
        try await testClientAndServer { inbound, outbound, context in
            for try await _ in inbound {}
        } shouldUpgrade: { _ in
            return nil
        } client: { inbound, outbound, context in
            for try await _ in inbound {}
        }        
    }

    func testNoConnection() async throws {
        let client = try HBWebSocketClient(
            url: .init("ws://localhost:10245"),
            logger: Logger(label: "TestNoConnection")
        ) { inbound, outbound, context in
        }
        do {
            try await client.run()
            XCTFail("testNoConnection: should not be successful")
        } catch is NIOConnectionError {
        }
    }

    func testTLS() async throws {
        try await testClientAndServer(serverTLSConfiguration: getServerTLSConfiguration()) { inbound, outbound, context in
            try await outbound.write(.text("Hello"))
        } getClient: { port, logger in
            var clientTLSConfiguration = try getClientTLSConfiguration()
            clientTLSConfiguration.certificateVerification = .noHostnameVerification
            return try HBWebSocketClient(
                url: .init("wss://localhost:\(port)"), 
                tlsConfiguration: clientTLSConfiguration,
                logger: logger
            ) { inbound, outbound, context in
                var inboundIterator = inbound.makeAsyncIterator()
                let msg = await inboundIterator.next()
                XCTAssertEqual(msg, .text("Hello"))
            }
        }
    }
/*
     func testPingPong() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

         let app = try self.setupClientAndServer(
             onServer: { _ in
             },
             onClient: { ws in
                 ws.onPong { _ in
                     promise.succeed()
                 }
                 ws.sendPing(promise: nil)
             }
         )
         defer { app.stop() }

         try promise.wait()
     }

     func testAutoPing() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(30))
         var count = 0

         let app = try self.setupClientAndServer(
             onServer: { ws in
                 ws.initiateAutoPing(interval: .seconds(2))
                 ws.onPong { _ in
                     count += 1
                     // wait for second pong, meaning auto ping caught the first one
                     if count == 2 {
                         promise.succeed()
                     }
                 }
             },
             onClient: { _ in
             }
         )
         defer { app.stop() }

         try promise.wait()
     }

     func testUnsolicitedPong() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

         let app = try self.setupClientAndServer(
             onServer: { ws in
                 ws.onPong { _ in
                     promise.succeed()
                 }
             },
             onClient: { ws in
                 ws.sendPong(.init(), promise: nil)
             }
         )
         defer { app.stop() }

         try promise.wait()
     }

     func testQuery() throws {
         let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
         // add HTTP to WebSocket upgrade
         app.ws.addUpgrade()
         // on websocket connect.
         app.ws.on(
             "/test",
             shouldUpgrade: { request in
                 guard request.uri.queryParameters["connect"] != nil else { return request.failure(HBHTTPError(.badRequest)) }
                 return request.success(nil)
             },
             onUpgrade: { _, _ in }
         )
         try app.start()
         defer { app.stop() }

         let eventLoop = app.eventLoopGroup.next()
         let wsFuture = HBWebSocketClient.connect(
             url: HBURL("ws://localhost:\(app.server.port!)/test?connect"),
             configuration: .init(),
             on: eventLoop
         )
         _ = try wsFuture.wait()
     }

     func testAdditionalHeaders() throws {
         let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
         // add HTTP to WebSocket upgrade
         app.ws.addUpgrade()
         // on websocket connect.
         app.ws.on(
             "/test",
             shouldUpgrade: { request in
                 guard request.headers["Sec-WebSocket-Extensions"].first == "foo" else { return request.failure(HBHTTPError(.badRequest)) }
                 return request.success(nil)
             },
             onUpgrade: { _, _ in }
         )
         try app.start()
         defer { app.stop() }

         let eventLoop = app.eventLoopGroup.next()
         let wsFuture = HBWebSocketClient.connect(
             url: HBURL("ws://localhost:\(app.server.port!)/test"),
             headers: ["Sec-WebSocket-Extensions": "foo"],
             configuration: .init(),
             on: eventLoop
         )
         _ = try wsFuture.wait()
     }
 }

 @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
 extension HummingbirdWebSocketTests {
     func testServerAsyncReadWrite() async throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

         let app = try await self.setupClientAndServer(
             onServer: { ws in
                 let stream = ws.readStream()
                 Task {
                     for try await data in stream {
                         XCTAssertEqual(data, .text("Hello"))
                     }
                     ws.onClose { _ in
                         promise.succeed()
                     }
                 }
             },
             onClient: { ws in
                 try await ws.write(.text("Hello"))
                 try await ws.close()
             }
         )
         defer { app.stop() }

         try promise.wait()
     }*/
 }
 
