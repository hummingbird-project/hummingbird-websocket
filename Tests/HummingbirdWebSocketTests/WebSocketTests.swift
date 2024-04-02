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
import HummingbirdTesting
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
        serverChannel: HTTPChannelBuilder<some HTTPChannelHandler>,
        getClient: @escaping @Sendable (Int, Logger) throws -> WebSocketClient
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
            let router = Router()
            let serviceGroup: ServiceGroup
            let app = Application(
                router: router,
                server: serverChannel,
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
                let client = try await getClient(promise.wait(), clientLogger)
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
        server serverHandler: @escaping WebSocketDataHandler<WebSocketContext>,
        shouldUpgrade: @escaping @Sendable (HTTPRequest) throws -> HTTPFields? = { _ in return [:] },
        getClient: @escaping @Sendable (Int, Logger) throws -> WebSocketClient
    ) async throws {
        let webSocketUpgrade: HTTPChannelBuilder<some HTTPChannelHandler> = .webSocketUpgrade { head, _, _ in
            if let headers = try shouldUpgrade(head) {
                return .upgrade(headers, serverHandler)
            } else {
                return .dontUpgrade
            }
        }
        if let serverTLSConfiguration {
            try await self.testClientAndServer(
                serverChannel: .tls(webSocketUpgrade, tlsConfiguration: serverTLSConfiguration),
                getClient: getClient
            )
        } else {
            try await self.testClientAndServer(
                serverChannel: webSocketUpgrade,
                getClient: getClient
            )
        }
    }

    func testClientAndServer(
        serverTLSConfiguration: TLSConfiguration? = nil,
        server serverHandler: @escaping WebSocketDataHandler<WebSocketContext>,
        shouldUpgrade: @escaping @Sendable (HTTPRequest) throws -> HTTPFields? = { _ in return [:] },
        client clientHandler: @escaping WebSocketDataHandler<WebSocketContext>
    ) async throws {
        try await self.testClientAndServer(
            serverTLSConfiguration: serverTLSConfiguration,
            server: serverHandler,
            shouldUpgrade: shouldUpgrade,
            getClient: { port, logger in
                try WebSocketClient(
                    url: .init("ws://localhost:\(port)"),
                    logger: logger,
                    handler: clientHandler
                )
            }
        )
    }

    func testClientAndServerWithRouter(
        webSocketRouter: Router<some WebSocketRequestContext>,
        getClient: @escaping @Sendable (Int, Logger) throws -> WebSocketClient
    ) async throws {
        let webSocketUpgrade: HTTPChannelBuilder<some HTTPChannelHandler> = .webSocketUpgrade(webSocketRouter: webSocketRouter)
        try await self.testClientAndServer(
            serverChannel: webSocketUpgrade,
            getClient: getClient
        )
    }

    // MARK: Tests

    func testServerToClientMessage() async throws {
        try await self.testClientAndServer { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        } client: { inbound, _, _ in
            var inboundIterator = inbound.makeAsyncIterator()
            let msg = try await inboundIterator.next()
            XCTAssertEqual(msg, .text("Hello"))
        }
    }

    func testClientToServerMessage() async throws {
        try await self.testClientAndServer { inbound, _, _ in
            var inboundIterator = inbound.makeAsyncIterator()
            let msg = try await inboundIterator.next()
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
            let msg = try await inboundIterator.next()
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
        do {
            try await self.testClientAndServer { inbound, _, _ in
                for try await _ in inbound {}
            } shouldUpgrade: { _ in
                return nil
            } client: { inbound, _, _ in
                for try await _ in inbound {}
            }
        } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
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
                let msg = try await inboundIterator.next()
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
                    let msg = try await inboundIterator.next()
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
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        router.ws("/ws2") { _, _ in
            return .upgrade([:])
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("Two"))
        }
        try await self.testClientAndServerWithRouter(webSocketRouter: router) { port, logger in
            try WebSocketClient(url: .init("ws://localhost:\(port)/ws1"), logger: logger) { inbound, _, _ in
                var inboundIterator = inbound.makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("One"))
            }
        }
        try await self.testClientAndServerWithRouter(webSocketRouter: router) { port, logger in
            try WebSocketClient(url: .init("ws://localhost:\(port)/ws2"), logger: logger) { inbound, _, _ in
                var inboundIterator = inbound.makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("Two"))
            }
        }
    }

    func testWebSocketMiddleware() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.group("/ws")
            .add(middleware: WebSocketUpgradeMiddleware { _, _ in
                return .upgrade([:])
            } onUpgrade: { _, outbound, _ in
                try await outbound.write(.text("One"))
            })
            .get { _, _ -> Response in return .init(status: .ok) }
        do {
            try await self.testClientAndServerWithRouter(webSocketRouter: router) { port, logger in
                try WebSocketClient(url: .init("ws://localhost:\(port)/ws"), logger: logger) { _, _, _ in }
            }
        }
    }

    func testRouteSelectionFail() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            return .upgrade([:])
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        do {
            try await self.testClientAndServerWithRouter(webSocketRouter: router) { port, logger in
                try WebSocketClient(url: .init("ws://localhost:\(port)/not-ws"), logger: logger) { _, _, _ in }
            }
        } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
    }

    /// Test context from router is passed through to web socket
    func testRouterContextUpdate() async throws {
        struct MyRequestContext: WebSocketRequestContext {
            var coreContext: CoreRequestContext
            var webSocket: WebSocketRouterContext<MyRequestContext>
            var name: String

            init(channel: Channel, logger: Logger) {
                self.coreContext = .init(allocator: channel.allocator, logger: logger)
                self.webSocket = .init()
                self.name = ""
            }
        }
        struct MyMiddleware: RouterMiddleware {
            func handle(_ request: Request, context: MyRequestContext, next: (Request, MyRequestContext) async throws -> Response) async throws -> Response {
                var context = context
                context.name = "Roger Moore"
                return try await next(request, context)
            }
        }
        let router = Router(context: MyRequestContext.self)
        router.middlewares.add(MyMiddleware())
        router.ws("/ws") { _, _ in
            return .upgrade([:])
        } onUpgrade: { _, outbound, context in
            try await outbound.write(.text(context.name))
        }
        do {
            try await self.testClientAndServerWithRouter(webSocketRouter: router) { port, logger in
                try WebSocketClient(url: .init("ws://localhost:\(port)/ws"), logger: logger) { inbound, _, _ in
                    let text = try await inbound.first { _ in true }
                    XCTAssertEqual(text, .text("Roger Moore"))
                }
            }
        } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
    }

    func testHTTPRequest() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            return .upgrade([:])
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        }
        router.get("/http") { _, _ in
            return "Hello"
        }
        let application = Application(
            router: router,
            server: .webSocketUpgrade(webSocketRouter: router)
        )
        try await application.test(.live) { client in
            try await client.execute(uri: "/http", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "Hello")
            }
        }
    }

    func testAutoPing() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { inbound, _, _ in
            for try await _ in inbound {}
        }
        let webSocketUpgrade: HTTPChannelBuilder<some HTTPChannelHandler> = .webSocketUpgrade(
            webSocketRouter: router,
            configuration: .init(autoPing: .enabled(timePeriod: .milliseconds(50)))
        )
        try await self.testClientAndServer(serverChannel: webSocketUpgrade) { port, logger in
            try WebSocketClient(
                url: .init("ws://localhost:\(port)/ws"),
                configuration: .init(additionalHeaders: [.secWebSocketExtensions: "hb"]),
                logger: logger
            ) { inbound, _, _ in
                // don't handle any inbound data for a period much longer than the auto ping period
                try await Task.sleep(for: .milliseconds(500))
                for try await _ in inbound {}
            }
        }
    }
}

extension Logger {
    /// Create new Logger with additional metadata value
    /// - Parameters:
    ///   - metadataKey: Metadata key
    ///   - value: Metadata value
    /// - Returns: Logger
    func with(metadataKey: String, value: MetadataValue) -> Logger {
        var logger = self
        logger[metadataKey: metadataKey] = value
        return logger
    }
}
