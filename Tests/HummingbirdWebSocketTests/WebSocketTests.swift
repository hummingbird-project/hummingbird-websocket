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

import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
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
        serverTLSConfiguration: TLSConfiguration? = nil,
        server serverHandler: @escaping WebSocketDataCallbackHandler.Callback,
        shouldUpgrade: @escaping @Sendable (HTTPRequest) throws -> HTTPFields? = { _ in return [:] },
        getClient: @escaping @Sendable (Int, Logger) throws -> WebSocketClient
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let logger = {
                var logger = Logger(label: "WebSocketTest")
                logger.logLevel = .debug
                return logger
            }()
            let router = Router()
            let serviceGroup: ServiceGroup
            let webSocketUpgrade: HTTPChannelBuilder<some HTTPChannelHandler> = .webSocketUpgrade { head, _, _ in
                if let headers = try shouldUpgrade(head) {
                    return .upgrade(headers, WebSocketDataCallbackHandler(serverHandler))
                } else {
                    return .dontUpgrade
                }
            }
            if let serverTLSConfiguration {
                let app = try Application(
                    router: router,
                    server: .tls(webSocketUpgrade, tlsConfiguration: serverTLSConfiguration),
                    onServerRunning: { channel in await promise.complete(channel.localAddress!.port!) },
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
                let app = Application(
                    router: router,
                    server: webSocketUpgrade,
                    onServerRunning: { channel in await promise.complete(channel.localAddress!.port!) },
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
                try await client.run()
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
        serverTLSConfiguration: TLSConfiguration? = nil,
        server serverHandler: @escaping WebSocketDataCallbackHandler.Callback,
        shouldUpgrade: @escaping @Sendable (HTTPRequest) throws -> HTTPFields? = { _ in return [:] },
        client clientHandler: @escaping WebSocketDataCallbackHandler.Callback
    ) async throws {
        try await self.testClientAndServer(
            serverTLSConfiguration: serverTLSConfiguration,
            server: serverHandler,
            shouldUpgrade: shouldUpgrade,
            getClient: { port, logger in
                try WebSocketClient(
                    url: .init("ws://localhost:\(port)"),
                    logger: logger,
                    process: clientHandler
                )
            }
        )
    }

    func testClientAndServerWithRouter(
        webSocketRouter: Router<some WebSocketRequestContext>,
        uri: URI,
        getClient: @escaping @Sendable (Int, Logger) throws -> WebSocketClient
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let logger = {
                var logger = Logger(label: "WebSocketTest")
                logger.logLevel = .debug
                return logger
            }()
            let router = Router()
            let serviceGroup: ServiceGroup
            let app = Application(
                router: router,
                server: .webSocketUpgrade(webSocketRouter: webSocketRouter),
                onServerRunning: { channel in await promise.complete(channel.localAddress!.port!) },
                logger: logger
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
                let client = try await getClient(promise.wait(), logger)
                try await client.run()
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

    // MARK: Tests

    func testServerToClientMessage() async throws {
        try await self.testClientAndServer { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        } client: { inbound, _, _ in
            var inboundIterator = inbound.makeAsyncIterator()
            let msg = await inboundIterator.next()
            XCTAssertEqual(msg, .text("Hello"))
        }
    }

    func testClientToServerMessage() async throws {
        try await self.testClientAndServer { inbound, _, _ in
            var inboundIterator = inbound.makeAsyncIterator()
            let msg = await inboundIterator.next()
            XCTAssertEqual(msg, .text("Hello"))
        } client: { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        }
    }

    func testClientToServerSplitPacket() async throws {
        try await self.testClientAndServer { inbound, outbound, _ in
            for try await packet in inbound {
                try await outbound.write(.custom(packet.webSocketFrame))
            }
        } client: { inbound, outbound, _ in
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
        try await self.testClientAndServer { inbound, outbound, _ in
            let buffer = ByteBuffer(repeating: 1, count: (1 << 14) + 1)
            try await outbound.write(.binary(buffer))
            for try await _ in inbound {}
        } client: { inbound, _, _ in
            for try await _ in inbound {}
        }
    }

    func testNotWebSocket() async throws {
        // currently disabled as NIO websocket code doesnt shutdown correctly here
        // try XCTSkipIf(true)
        do {
            try await self.testClientAndServer { inbound, _, _ in
                for try await _ in inbound {}
            } shouldUpgrade: { _ in
                return nil
            } client: { inbound, _, _ in
                for try await _ in inbound {}
            }
        } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {
        } catch let error as ChannelError where error == .inappropriateOperationForState {}
    }

    func testNoConnection() async throws {
        let client = try WebSocketClient(
            url: .init("ws://localhost:10245"),
            logger: Logger(label: "TestNoConnection")
        ) { _, _, _ in
        }
        do {
            try await client.run()
            XCTFail("testNoConnection: should not be successful")
        } catch is NIOConnectionError {}
    }

    func testTLS() async throws {
        try await self.testClientAndServer(serverTLSConfiguration: getServerTLSConfiguration()) { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        } getClient: { port, logger in
            var clientTLSConfiguration = try getClientTLSConfiguration()
            clientTLSConfiguration.certificateVerification = .none
            return try WebSocketClient(
                url: .init("wss://localhost:\(port)"),
                tlsConfiguration: clientTLSConfiguration,
                logger: logger
            ) { inbound, _, _ in
                var inboundIterator = inbound.makeAsyncIterator()
                let msg = await inboundIterator.next()
                XCTAssertEqual(msg, .text("Hello"))
            }
        }
    }

    func testURLPath() async throws {
        try await self.testClientAndServer { inbound, _, _ in
            for try await _ in inbound {}
        } shouldUpgrade: { head in
            XCTAssertEqual(head.path, "/ws")
            return [:]
        } getClient: { port, logger in
            try WebSocketClient(
                url: .init("ws://localhost:\(port)/ws"),
                logger: logger
            ) { _, _, _ in
            }
        }
    }

    func testQueryParameters() async throws {
        try await self.testClientAndServer { inbound, _, _ in
            for try await _ in inbound {}
        } shouldUpgrade: { head in
            let request = Request(head: head, body: .init(buffer: ByteBuffer()))
            XCTAssertEqual(request.uri.query, "query=parameters&test=true")
            return [:]
        } getClient: { port, logger in
            try WebSocketClient(
                url: .init("ws://localhost:\(port)/ws?query=parameters&test=true"),
                logger: logger
            ) { _, _, _ in
            }
        }
    }

    func testAdditionalHeaders() async throws {
        try await self.testClientAndServer { inbound, _, _ in
            for try await _ in inbound {}
        } shouldUpgrade: { head in
            let request = Request(head: head, body: .init(buffer: ByteBuffer()))
            XCTAssertEqual(request.headers[.secWebSocketExtensions], "hb")
            return [:]
        } getClient: { port, logger in
            try WebSocketClient(
                url: .init("ws://localhost:\(port)/ws?query=parameters&test=true"),
                configuration: .init(additionalHeaders: [.secWebSocketExtensions: "hb"]),
                logger: logger
            ) { _, _, _ in
            }
        }
    }

    // test WebSocketClient.connect
    func testClientConnect() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let logger = {
                var logger = Logger(label: "WebSocketTest")
                logger.logLevel = .debug
                return logger
            }()
            let router = Router()
            let serviceGroup: ServiceGroup
            let app = Application(
                router: router,
                server: .webSocketUpgrade { _, _, _ in
                    return .upgrade([:]) { _, outbound, _ in
                        try await outbound.write(.text("Hello"))
                    }
                },
                onServerRunning: { channel in await promise.complete(channel.localAddress!.port!) },
                logger: logger
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
                try await WebSocketClient.connect(url: .init("ws://localhost:\(promise.wait())/ws"), logger: logger) { inbound, _, _ in
                    var inboundIterator = inbound.makeAsyncIterator()
                    let msg = await inboundIterator.next()
                    XCTAssertEqual(msg, .text("Hello"))
                }
            }
            try await group.next()
            await serviceGroup.triggerGracefulShutdown()
        }
    }

    func testRouteSelection() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws1") { _, _ in
            return .upgrade([:])
        } handle: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        router.ws("/ws2") { _, _ in
            return .upgrade([:])
        } handle: { _, outbound, _ in
            try await outbound.write(.text("Two"))
        }
        try await self.testClientAndServerWithRouter(webSocketRouter: router, uri: "localhost:8080") { port, logger in
            try WebSocketClient(url: .init("ws://localhost:\(port)/ws1"), logger: logger) { inbound, _, _ in
                var inboundIterator = inbound.makeAsyncIterator()
                let msg = await inboundIterator.next()
                XCTAssertEqual(msg, .text("One"))
            }
        }
        try await self.testClientAndServerWithRouter(webSocketRouter: router, uri: "localhost:8080") { port, logger in
            try WebSocketClient(url: .init("ws://localhost:\(port)/ws2"), logger: logger) { inbound, _, _ in
                var inboundIterator = inbound.makeAsyncIterator()
                let msg = await inboundIterator.next()
                XCTAssertEqual(msg, .text("Two"))
            }
        }
    }

    func testRouteSelectionFail() async throws {
        try XCTSkipIf(true)
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            return .upgrade([:])
        } handle: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        try await self.testClientAndServerWithRouter(webSocketRouter: router, uri: "localhost:8080") { port, logger in
            try WebSocketClient(url: .init("ws://localhost:\(port)/not-ws"), logger: logger) { _, _, _ in }
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

     */
}
