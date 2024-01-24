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
import HummingbirdWebSocket
import Logging
import NIOCore
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
        server: @escaping HBWebSocketDataCallbackHandler.Callback,
        client: @escaping HBWebSocketDataCallbackHandler.Callback
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            var logger = Logger(label: "WebSocketTest")
            logger.logLevel = .debug

            let router = HBRouter()
            let app = HBApplication(
                router: router,
                server: .webSocketUpgrade { _,_ in
                    .upgrade(.init(), server)
                },
                onServerRunning: { channel in await promise.complete(channel.localAddress!.port!)},
                logger: logger
            )
            let serviceGroup = ServiceGroup(
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
                let client = await HBClient(
                    childChannel: WebSocketClientChannel(handler: HBWebSocketDataCallbackHandler(client)), 
                    address: .hostname("localhost", port: promise.wait()),
                    logger: app.logger
                )
                try await client.run()
            }
            try await group.next()
            await serviceGroup.triggerGracefulShutdown()
        }
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

/*
     func testClientAndServerSplitPacket() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(5))
         let app = try self.setupClientAndServer(
             onServer: { ws in
                 ws.onRead { data, _ in
                     XCTAssertEqual(data, .text("Hello World!"))
                     promise.succeed()
                 }
             },
             onClient: { ws in
                 let buffer = ByteBuffer(string: "Hello ")
                 ws.send(buffer: buffer, opcode: .text, fin: false, promise: nil)
                 let buffer2 = ByteBuffer(string: "World!")
                 ws.send(buffer: buffer2, opcode: .text, fin: true, promise: nil)
             }
         )
         defer { app.stop() }

         try promise.wait()
     }

     func testClientAndServerLargeBuffer() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(50))
         let buffer = self.createRandomBuffer(size: 600_000)

         let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
         // add HTTP to WebSocket upgrade
         app.ws.addUpgrade(maxFrameSize: 1_000_000)
         // on websocket connect.
         app.ws.on(
             "/test",
             onUpgrade: { _, ws in
                 ws.onRead { data, ws in
                     XCTAssertEqual(data, .binary(buffer))
                     ws.write(.binary(buffer), promise: nil)
                 }
             }
         )
         try app.start()
         defer { app.stop() }

         let eventLoop = app.eventLoopGroup.next()
         let wsFuture = HBWebSocketClient.connect(
             url: HBURL("ws://localhost:\(app.server.port!)/test"),
             configuration: .init(maxFrameSize: 1_000_000),
             on: eventLoop
         ).map { ws in
             ws.onRead { data, _ in
                 XCTAssertEqual(data, .binary(buffer))
                 promise.succeed()
             }
             ws.onClose { _ in
                 promise.fail(Error.unexpectedClose)
             }
             ws.write(.binary(buffer), promise: nil)
         }
         wsFuture.cascadeFailure(to: promise.promise)
         _ = try promise.wait()
     }

     func testServerImmediateWrite() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(50))

         let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
         // add HTTP to WebSocket upgrade
         app.ws.addUpgrade(maxFrameSize: 1_000_000)
         // on websocket connect.
         app.ws.on(
             "/test",
             onUpgrade: { _, ws in
                 ws.write(.text("hello"), promise: nil)
             }
         )
         try app.start()
         defer { app.stop() }

         let eventLoop = app.eventLoopGroup.next()
         let wsFuture = HBWebSocketClient.connect(
             url: HBURL("ws://localhost:\(app.server.port!)/test"),
             configuration: .init(maxFrameSize: 1_000_000),
             on: eventLoop
         ) { data, _ in
             XCTAssertEqual(data, .text("hello"))
             promise.succeed()
         }.map { ws in
             ws.onClose { _ in
                 promise.fail(Error.unexpectedClose)
             }
         }
         wsFuture.cascadeFailure(to: promise.promise)
         _ = try promise.wait()
     }

     func testNotWebSocket() throws {
         let app = HBApplication(configuration: .init(address: .hostname(port: 0)))
         app.router.get("/test") { _ in
             "hello"
         }
         try app.start()
         defer { app.stop() }

         let eventLoop = Self.eventLoopGroup.next()
         let clientWS = HBWebSocketClient.connect(
             url: HBURL("ws://localhost:\(app.server.port!)/test"),
             configuration: .init(),
             on: eventLoop
         )
         XCTAssertThrowsError(try clientWS.wait()) { error in
             switch error {
             case HBWebSocketClient.Error.websocketUpgradeFailed:
                 break
             default:
                 XCTFail("\(error)")
             }
         }
     }

     func testNoConnection() throws {
         let eventLoop = Self.eventLoopGroup.next()
         let clientWS = HBWebSocketClient.connect(url: "http://localhost:10245", configuration: .init(), on: eventLoop)
         XCTAssertThrowsError(try clientWS.wait()) { error in
             switch error {
             case is NIOConnectionError:
                 break
             default:
                 XCTFail("\(error)")
             }
         }
     }

     func testClientCloseConnection() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

         let app = try self.setupClientAndServer(
             onServer: { ws in
                 ws.onClose { _ in
                     promise.succeed()
                 }
             },
             onClient: { ws in
                 ws.write(.text("Hello"), promise: nil)
                 ws.close(code: .normalClosure, promise: nil)
             }
         )
         defer { app.stop() }

         try promise.wait()
     }

     func testServerCloseConnection() throws {
         let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(10))

         let app = try self.setupClientAndServer(
             onServer: { ws in
                 ws.onRead { data, ws in
                     XCTAssertEqual(data, .text("Hello"))
                     ws.close(code: .normalClosure, promise: nil)
                 }
             },
             onClient: { ws in
                 ws.onClose { _ in
                     promise.succeed()
                 }
                 ws.write(.text("Hello"), promise: nil)
             }
         )
         defer { app.stop() }

         try promise.wait()
     }

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
 
