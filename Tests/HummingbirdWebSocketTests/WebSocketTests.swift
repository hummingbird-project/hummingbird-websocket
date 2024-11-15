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

import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTesting
import HummingbirdTLS
import HummingbirdWebSocket
import HummingbirdWSTesting
import Logging
import NIOCore
import NIOPosix
import NIOWebSocket
import ServiceLifecycle
import WSClient
import XCTest

/// Promise type.
actor Promise<Value: Sendable> {
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

    // MARK: Tests

    func testServerToClientMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .upgrade([:]) { _, outbound, context in
                    context.logger.info("testServerToClientMessage enter")
                    try await outbound.write(.text("Hello"))
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("Hello"))
            }
        }
    }

    func testClientToServerMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .upgrade([:]) { inbound, _, _ in
                    var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let msg = try await inboundIterator.next()
                    XCTAssertEqual(msg, .text("Hello"))
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { _, outbound, _ in
                try await outbound.write(.text("Hello"))
            }
        }
    }

    func testClientToServerSplitPacket() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .upgrade([:]) { inbound, outbound, _ in
                    for try await packet in inbound.messages(maxSize: .max) {
                        switch packet {
                        case .binary(let buffer):
                            try await outbound.write(.binary(buffer))
                        case .text(let string):
                            try await outbound.write(.text(string))
                        }
                    }
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { inbound, outbound, _ in
                let buffer = ByteBuffer(string: "Hello ")
                try await outbound.write(.custom(.init(fin: false, opcode: .text, data: buffer)))
                let buffer2 = ByteBuffer(string: "World!")
                try await outbound.write(.custom(.init(fin: true, opcode: .continuation, data: buffer2)))

                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("Hello World!"))
            }
        }
    }

    // test connection is closed when buffer is too large
    func testTooLargeBuffer() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        let rt = try await app.test(.live) { client in
            try await client.ws("/") { inbound, outbound, _ in
                let buffer = ByteBuffer(repeating: 1, count: (1 << 14) + 1)
                try await outbound.write(.binary(buffer))
                for try await _ in inbound {}
            }
        }
        XCTAssertEqual(rt?.closeCode, .messageTooLarge)
    }

    // test connection is closed when message size is too large
    func testTooLargeMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound.messages(maxSize: 1024) {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                try await outbound.withBinaryMessageWriter { write in
                    let buffer = ByteBuffer(repeating: 1, count: 1025)
                    try await write(buffer)
                    try await write(buffer)
                }
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .messageTooLarge)
        }
    }

    // test text message writer works
    func testTextMessageWriter() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .upgrade([:]) { inbound, outbound, _ in
                    try await outbound.withTextMessageWriter { writer in
                        try await writer("Merry Christmas ")
                        try await writer("and a ")
                        try await writer("Happy new year")
                    }
                    for try await _ in inbound {}
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let text = try await iterator.next()
                XCTAssertEqual(.text("Merry Christmas and a Happy new year"), text)
            }
        }
    }

    func testWebSocketUpgradeFailed() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                return .dontUpgrade
            }
        )
        try await app.test(.live) { client in
            do {
                try await client.ws("/") { inbound, _, _ in
                    for try await _ in inbound {}
                }
                XCTFail("WebSocket connect should have failed")
            } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
        }
    }

    func testNotWebSocket() async throws {
        let app = Application(
            router: Router(),
            server: .http1()
        )
        try await app.test(.live) { client in
            do {
                try await client.ws("/") { inbound, _, _ in
                    for try await _ in inbound {}
                }
                XCTFail("WebSocket connect should have failed")
            } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
        }
    }

    func testNoConnection() async throws {
        let client = WebSocketClient(
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            let promise = Promise<Int>()
            let app = try Application(
                router: Router(),
                server: .tls(
                    .http1WebSocketUpgrade { _, _, _ in
                        .upgrade([:]) { _, outbound, _ in
                            try await outbound.write(.text("Hello"))
                        }
                    },
                    tlsConfiguration: getServerTLSConfiguration()
                ),
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                onServerRunning: { channel in await promise.complete(channel.localAddress!.port!) },
                logger: Logger(label: "server")
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
            do {
                var clientTLSConfiguration = try getClientTLSConfiguration()
                clientTLSConfiguration.certificateVerification = .none
                try await WebSocketClient.connect(
                    url: "wss://localhost:\(promise.wait())/",
                    tlsConfiguration: clientTLSConfiguration,
                    logger: Logger(label: "client")
                ) { inbound, _, _ in
                    var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let msg = try await inboundIterator.next()
                    XCTAssertEqual(msg, .text("Hello"))
                }
                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }

    func testURLPath() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { head, _, _ in
                XCTAssertEqual(head.path, "/testURLPath")
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/testURLPath") { _, _, _ in }
        }
    }

    func testQueryParameters() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { head, _, _ in
                let request = Request(head: head, body: .init(buffer: ByteBuffer()))
                XCTAssertEqual(request.uri.query, "query=parameters&test=true")
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws?query=parameters&test=true") { _, _, _ in }
        }
    }

    func testAdditionalHeaders() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { head, _, _ in
                let request = Request(head: head, body: .init(buffer: ByteBuffer()))
                XCTAssertEqual(request.headers[.secWebSocketExtensions], "hb")
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/ws",
                configuration: .init(additionalHeaders: [.secWebSocketExtensions: "hb"])
            ) { _, _, _ in }
        }
    }

    func testRouteSelection() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws1") { _, _ in
            return .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        router.ws("/ws2") { _, _ in
            return .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("Two"))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router)
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws1") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("One"))
            }
            try await client.ws("/ws2") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("Two"))
            }
        }
    }

    func testAccessingRequestSelection() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { request, _ in
            guard request.uri.queryParameters["test"] != nil else { return .dontUpgrade }
            return .upgrade()
        } onUpgrade: { _, outbound, context in
            guard let test = context.request.uri.queryParameters["test"] else { return }
            try await outbound.write(.text(String(test)))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router)
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws?test=123") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                XCTAssertEqual(msg, .text("123"))
            }
            do {
                try await client.ws("/ws") { _, _, _ in }
                XCTFail("Shouldn't get here as websocket upgrade failed")
            } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
        }
    }

    func testWebSocketMiddleware() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.group("/middleware")
            .add(middleware: WebSocketUpgradeMiddleware { _, _ in
                return .upgrade()
            } onUpgrade: { _, outbound, _ in
                try await outbound.write(.text("One"))
            })
            // need to add router to ensure middleware runs
            .get { _, _ -> Response in return .init(status: .ok) }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router)
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/middleware") { _, _, _ in }
        }
    }

    func testRouteSelectionFail() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            return .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router)
        )
        _ = try await app.test(.live) { client in
            do {
                try await client.ws("/not-ws") { _, _, _ in }
                XCTFail("Shouldn't get here as connect failed")
            } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {}
        }
    }

    /// Test context from router is passed through to web socket
    func testRouterContextUpdate() async throws {
        struct MyRequestContext: RequestContext, WebSocketRequestContext {
            var coreContext: CoreRequestContextStorage
            var webSocket: WebSocketHandlerReference<MyRequestContext>
            var name: String

            init(source: Source) {
                self.coreContext = .init(source: source)
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
            return .upgrade()
        } onUpgrade: { _, outbound, context in
            try await outbound.write(.text(context.requestContext.name))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router)
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws") { inbound, _, _ in
                let text = try await inbound.messages(maxSize: .max).first { _ in true }
                XCTAssertEqual(text, .text("Roger Moore"))
            }
        }
    }

    func testHTTPRequest() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            return .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        }
        router.get("/http") { _, _ in
            return "Hello"
        }
        let application = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
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
        let application = Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(autoPing: .enabled(timePeriod: .milliseconds(50)))
            ),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await application.test(.live) { client in
            let frame = try await client.ws("/ws") { inbound, _, _ in
                // don't handle any inbound data for a period much longer than the auto ping period
                try await Task.sleep(for: .milliseconds(500))
                for try await _ in inbound {}
            }
            XCTAssertEqual(frame?.closeCode, .goingAway)
            XCTAssertEqual(frame?.reason, "Ping timeout")
        }
    }

    func testCloseCode() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { _, _, _ in }
            XCTAssertEqual(rt?.closeCode, .normalClosure)
        }
    }

    func testCloseReason() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { _, outbound, _ in
                    try await outbound.close(.unknown(3000), reason: "Because")
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, _, _ in
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .unknown(3000))
            XCTAssertEqual(rt?.reason, "Because")
        }
    }

    func testUnrecognisedOpcode() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                try await outbound.write(.custom(.init(fin: true, opcode: WebSocketOpcode(encodedWebSocketOpcode: 0x4)!, data: ByteBuffer())))
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .protocolError)
        }
    }

    func testInvalidPing() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                // ping frames should be finished
                try await outbound.write(.custom(.init(fin: false, opcode: .ping, data: ByteBuffer())))
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .protocolError)
        }
    }

    func testUnexpectedContinuation() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound.messages(maxSize: 1024) {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                // send continuation frame without an initial text or binary frame
                try await outbound.write(.custom(.init(fin: true, opcode: .continuation, data: ByteBuffer(repeating: 1, count: 16))))
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .protocolError)
        }
    }

    func testBadCloseCode() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { _, outbound, _ in
                var buffer = ByteBufferAllocator().buffer(capacity: 2)
                buffer.write(webSocketErrorCode: .unknown(999))
                try await outbound.write(.custom(.init(fin: true, opcode: .connectionClose, data: buffer)))
            }
            XCTAssertEqual(rt?.closeCode, .protocolError)
        }
    }

    func testBadControlFrame() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                // control frames can only have data length 125 bytes
                try await outbound.write(.custom(.init(fin: true, opcode: .ping, data: ByteBuffer(repeating: 1, count: 126))))
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .protocolError)
        }
    }

    #if compiler(>=6)
    func testInvalidUTF8Frame() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(configuration: .init(validateUTF8: true)) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound.messages(maxSize: .max) {}
                }
            }
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                let buffer = ByteBuffer(repeating: 0xFF, count: 16)
                try await outbound.write(.custom(.init(fin: true, opcode: .text, data: buffer)))
                for try await _ in inbound {}
            }
            XCTAssertEqual(rt?.closeCode, .dataInconsistentWithMessage)
        }
    }
    #endif

    // test WebSocket channel graceful shutdown
    func testGracefulShutdown() async throws {
        await withThrowingTaskGroup(of: Void.self) { group in
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
                server: .http1WebSocketUpgrade { _, _, _ in
                    return .upgrade { inbound, outbound, _ in
                        try await outbound.write(.text("Hello"))
                        for try await _ in inbound {
                            XCTFail("Shouldn't receive anything")
                        }
                    }
                },
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
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
            let connectPromise = Promise<Void>()
            group.addTask {
                try await WebSocketClient.connect(url: .init("ws://localhost:\(promise.wait())/ws"), logger: logger) { inbound, _, _ in
                    await connectPromise.complete(())
                    var iterator = inbound.makeAsyncIterator()
                    let firstMessage = try await iterator.nextMessage(maxSize: .max)
                    XCTAssertEqual(firstMessage, .text("Hello"))
                    while try await iterator.next() != nil {}
                }
            }
            _ = await connectPromise.wait()
            await serviceGroup.triggerGracefulShutdown()
        }
    }

    func testClientErrorHandling() async throws {
        struct ClientError: Error {}
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        )
        try await app.test(.live) { client in
            do {
                _ = try await client.ws("/") { _, _, _ in
                    throw ClientError()
                }
                XCTFail("Shouldnt reach here")
            } catch is ClientError {
            } catch {
                XCTFail("Throwing wrong error")
            }
        }
    }

    func testServerErrorHandling() async throws {
        struct ServerError: Error {}
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { _, _, _ in
                    throw ServerError()
                }
            }
        )
        try await app.test(.live) { client in
            let closeFrame = try await client.ws("/") { inbound, _, _ in
                for try await _ in inbound {}
            }
            XCTAssertEqual(closeFrame?.closeCode, .unexpectedServerError)
        }
    }
}
