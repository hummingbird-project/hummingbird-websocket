//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import AsyncHTTPClient
import Atomics
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOPosix
import NIOWebSocket
import ServiceLifecycle
import Testing
import WSClient

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

@Suite(.serialized)
struct HummingbirdWebSocketTests {
    func createRandomBuffer(size: Int) -> ByteBuffer {
        // create buffer
        var data = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            data[i] = UInt8.random(in: 0...255)
        }
        return ByteBuffer(bytes: data)
    }

    // MARK: Tests

    @Test func testServerToClientMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { _, outbound, context in
                    context.logger.info("testServerToClientMessage enter")
                    try await outbound.write(.text("Hello"))
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                #expect(msg == .text("Hello"))
            }
        }
    }

    @Test func testClientToServerMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let msg = try await inboundIterator.next()
                    #expect(msg == .text("Hello"))
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { _, outbound, _ in
                try await outbound.write(.text("Hello"))
            }
        }
    }

    @Test func testClientToServerSplitPacket() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    for try await packet in inbound.messages(maxSize: .max) {
                        switch packet {
                        case .binary(let buffer):
                            try await outbound.write(.binary(buffer))
                        case .text(let string):
                            try await outbound.write(.text(string))
                        }
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { inbound, outbound, _ in
                let buffer = ByteBuffer(string: "Hello ")
                try await outbound.write(.custom(.init(fin: false, opcode: .text, data: buffer)))
                let buffer2 = ByteBuffer(string: "World!")
                try await outbound.write(.custom(.init(fin: true, opcode: .continuation, data: buffer2)))

                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                #expect(msg == .text("Hello World!"))
            }
        }
    }

    // test connection is closed when buffer is too large
    @Test func testTooLargeBuffer() async throws {
        var logger = Logger(label: "testTooLargeBuffer")
        logger.logLevel = .trace
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(configuration: .init(maxFrameSize: (1 << 13))) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            logger: logger
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                let buffer = ByteBuffer(repeating: 1, count: (1 << 13) + 1)
                try await outbound.write(.binary(buffer))
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .messageTooLarge)
        }
    }

    // test connection is closed when message size is too large
    @Test func testTooLargeMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound.messages(maxSize: 1024) {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
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
            #expect(rt?.closeCode == .messageTooLarge)
        }
    }

    // test text message writer works
    @Test func testTextMessageWriter() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    try await outbound.withTextMessageWriter { writer in
                        try await writer("Merry Christmas ")
                        try await writer("and a ")
                        try await writer("Happy new year")
                    }
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/") { inbound, _, _ in
                var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let text = try await iterator.next()
                #expect(.text("Merry Christmas and a Happy new year") == text)
            }
        }
    }

    @Test func testWebSocketUpgradeFailed() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .dontUpgrade
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            _ = await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await client.ws("/") { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        }
    }

    @Test func testNotWebSocket() async throws {
        let app = Application(
            router: Router(),
            server: .http1(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            _ = await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await client.ws("/") { inbound, _, _ in
                    for try await _ in inbound {}
                }
            }
        }
    }

    @Test func testNoConnection() async throws {
        let client = WebSocketClient(
            url: .init("ws://localhost:10245"),
            logger: Logger(label: "TestNoConnection")
        ) { _, _, _ in
        }
        await #expect(throws: NIOConnectionError.self) {
            try await client.run()
        }
    }

    @Test func testTLS() async throws {
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
                clientTLSConfiguration.certificateVerification = .fullVerification
                try await WebSocketClient.connect(
                    url: "wss://localhost:\(promise.wait())/",
                    configuration: .init(sniHostname: testServerName),
                    tlsConfiguration: clientTLSConfiguration,
                    logger: Logger(label: "client")
                ) { inbound, _, _ in
                    var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let msg = try await inboundIterator.next()
                    #expect(msg == .text("Hello"))
                }
                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }

    @Test func testURLPath() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { head, _, _ in
                #expect(head.path == "/testURLPath")
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/testURLPath") { _, _, _ in }
        }
    }

    @Test func testQueryParameters() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { head, _, _ in
                let request = Request(head: head, body: .init(buffer: ByteBuffer()))
                #expect(request.uri.query == "query=parameters&test=true")
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws?query=parameters&test=true") { _, _, _ in }
        }
    }

    @Test func testAdditionalHeaders() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { head, _, _ in
                let request = Request(head: head, body: .init(buffer: ByteBuffer()))
                #expect(request.headers[.secWebSocketExtensions] == "hb")
                return .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/ws",
                configuration: .init(additionalHeaders: [.secWebSocketExtensions: "hb"])
            ) { _, _, _ in }
        }
    }

    @Test func testRouteSelection() async throws {
        var logger = Logger(label: "testRouteSelection")
        logger.logLevel = .trace
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws1") { _, _ in
            .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        router.ws("/ws2") { _, _ in
            .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("Two"))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            logger: logger
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws1") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                #expect(msg == .text("One"))
            }
            try await client.ws("/ws2") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                #expect(msg == .text("Two"))
            }
        }
    }

    @Test func testAccessingRequestSelection() async throws {
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
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/ws?test=123") { inbound, _, _ in
                var inboundIterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                let msg = try await inboundIterator.next()
                #expect(msg == .text("123"))
            }
            await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await client.ws("/ws") { _, _, _ in }
            }
        }
    }

    @Test func testWebSocketMiddleware() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.group("/middleware")
            .add(
                middleware: WebSocketUpgradeMiddleware { _, _ in
                    .upgrade()
                } onUpgrade: { _, outbound, _ in
                    try await outbound.write(.text("One"))
                }
            )
            // need to add router to ensure middleware runs
            .get { _, _ -> Response in .init(status: .ok) }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws("/middleware") { _, _, _ in }
        }
    }

    @Test func testRouteSelectionFail() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("One"))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await client.ws("/not-ws") { _, _, _ in }
            }
        }
    }

    /// Test context from router is passed through to web socket
    @Test func testRouterContextUpdate() async throws {
        var logger = Logger(label: "testRouterContextUpdate")
        logger.logLevel = .trace
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
            func handle(
                _ request: Request,
                context: MyRequestContext,
                next: (Request, MyRequestContext) async throws -> Response
            ) async throws -> Response {
                var context = context
                context.name = "Roger Moore"
                return try await next(request, context)
            }
        }
        let router = Router(context: MyRequestContext.self)
        router.middlewares.add(MyMiddleware())
        router.ws("/ws") { _, _ in
            .upgrade()
        } onUpgrade: { _, outbound, context in
            try await outbound.write(.text(context.requestContext.name))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            logger: logger
        )
        _ = try await app.test(.live) { client in
            var logger = Logger(label: "testRouterContextUpdate-client")
            logger.logLevel = .trace
            try await client.ws("/ws", logger: logger) { inbound, _, _ in
                let text = try await inbound.messages(maxSize: .max).first { _ in true }
                #expect(text == .text("Roger Moore"))
            }
        }
    }

    @Test func testHTTPRequest() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws") { _, _ in
            .upgrade()
        } onUpgrade: { _, outbound, _ in
            try await outbound.write(.text("Hello"))
        }
        router.get("/http") { _, _ in
            "Hello"
        }
        let application = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await application.test(.live) { client in
            try await client.execute(uri: "/http", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "Hello")
            }
        }
    }

    @Test func testAutoPing() async throws {
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
            #expect(frame?.closeCode == .goingAway)
            #expect(frame?.reason == "Ping timeout")
        }
    }

    @Test func testCloseCode() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { _, _, _ in }
            #expect(rt?.closeCode == .normalClosure)
        }
    }

    @Test func testCloseReason() async throws {
        var logger = Logger(label: "testCloseReason")
        logger.logLevel = .trace
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { _, outbound, _ in
                    try await outbound.close(.unknown(3000), reason: "Because")
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            logger: logger
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, _, _ in
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .unknown(3000))
            #expect(rt?.reason == "Because")
        }
    }

    @Test func testCloseTimeout() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { _, _, _ in
                    try await cancelWhenGracefulShutdown {
                        try await Task.sleep(for: .seconds(15))
                        Issue.record("Should not reach here")
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            _ = try await client.ws("/", configuration: .init(closeTimeout: .seconds(1))) { _, outbound, _ in
                try await outbound.write(.text("Hello"))
            }
        }
    }

    @Test func testUnrecognisedOpcode() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                try await outbound.write(.custom(.init(fin: true, opcode: WebSocketOpcode(encodedWebSocketOpcode: 0x4)!, data: ByteBuffer())))
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .protocolError)
        }
    }

    @Test func testInvalidPing() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                // ping frames should be finished
                try await outbound.write(.custom(.init(fin: false, opcode: .ping, data: ByteBuffer())))
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .protocolError)
        }
    }

    @Test func testUnexpectedContinuation() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound.messages(maxSize: 1024) {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                // send continuation frame without an initial text or binary frame
                try await outbound.write(.custom(.init(fin: true, opcode: .continuation, data: ByteBuffer(repeating: 1, count: 16))))
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .protocolError)
        }
    }

    @Test func testBadCloseCode() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { _, outbound, _ in
                var buffer = ByteBufferAllocator().buffer(capacity: 2)
                buffer.write(webSocketErrorCode: .unknown(999))
                try await outbound.write(.custom(.init(fin: true, opcode: .connectionClose, data: buffer)))
            }
            #expect(rt?.closeCode == .protocolError)
        }
    }

    @Test func testBadControlFrame() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                // control frames can only have data length 125 bytes
                try await outbound.write(.custom(.init(fin: true, opcode: .ping, data: ByteBuffer(repeating: 1, count: 126))))
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .protocolError)
        }
    }

    @Test func testInvalidUTF8Frame() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(configuration: .init(validateUTF8: true)) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound.messages(maxSize: .max) {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            let rt = try await client.ws("/") { inbound, outbound, _ in
                let buffer = ByteBuffer(repeating: 0xFF, count: 16)
                try await outbound.write(.custom(.init(fin: true, opcode: .text, data: buffer)))
                for try await _ in inbound {}
            }
            #expect(rt?.closeCode == .dataInconsistentWithMessage)
        }
    }

    // test WebSocket channel graceful shutdown
    @Test func testGracefulShutdown() async throws {
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
                    .upgrade { inbound, outbound, _ in
                        try await outbound.write(.text("Hello"))
                        for try await _ in inbound {
                            Issue.record("Shouldn't receive anything")
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
                    #expect(firstMessage == .text("Hello"))
                    while try await iterator.next() != nil {}
                }
            }
            _ = await connectPromise.wait()
            await serviceGroup.triggerGracefulShutdown()
        }
    }

    @Test func testClientErrorHandling() async throws {
        struct ClientError: Error {}
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await _ in inbound {}
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            _ = await #expect(throws: ClientError.self) {
                _ = try await client.ws("/") { _, _, _ in
                    throw ClientError()
                }
            }
        }
    }

    @Test func testServerErrorHandling() async throws {
        var logger = Logger(label: "testServerErrorHandling")
        logger.logLevel = .trace
        struct ServerError: Error {}
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade { _, _, _ in
                .upgrade([:]) { _, _, _ in
                    throw ServerError()
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            logger: logger
        )
        try await app.test(.live) { client in
            var logger = Logger(label: "testServerErrorHandling-client")
            logger.logLevel = .trace
            let closeFrame = try await client.ws("/", logger: logger) { inbound, _, _ in
                for try await _ in inbound {}
            }
            #expect(closeFrame?.closeCode == .unexpectedServerError)
        }
    }

    @Test func testCancelledRequest() async throws {
        let httpClient = HTTPClient()
        let (stream, cont) = AsyncStream.makeStream(of: Int.self)

        let router = Router()
        router.post("/") { request, context in
            let b = try await request.body.collect(upTo: .max)
            return Response(status: .ok, body: .init(byteBuffer: b))
        }
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade { request, channel, logger in
                .dontUpgrade
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: {
                cont.yield($0.localAddress!.port!)
            }
        )
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let serviceGroup = ServiceGroup(
                    configuration: .init(
                        services: [app],
                        gracefulShutdownSignals: [.sigterm, .sigint],
                        logger: Logger(label: "SG")
                    )
                )

                group.addTask {
                    try await serviceGroup.run()
                }

                let port = await stream.first { _ in true }!
                // setup task making request to server that should take longer than a second
                let task = Task {
                    let count = ManagedAtomic(0)
                    let stream = AsyncStream {
                        let value = count.loadThenWrappingIncrement(by: 1, ordering: .relaxed)
                        if value < 16 {
                            try? await Task.sleep(for: .milliseconds(200))
                            return ByteBuffer(repeating: 0, count: 256)
                        } else {
                            return nil
                        }
                    }
                    var request = HTTPClientRequest(url: "http://localhost:\(port)")
                    request.method = .POST
                    request.body = .stream(stream, length: .known(Int64(4096)))
                    let response = try await httpClient.execute(request, deadline: .now() + .minutes(30))
                    _ = try await response.body.collect(upTo: .max)
                }

                // wait for a second and then cancel HTTP request task
                try await Task.sleep(for: .seconds(1))
                task.cancel()
                await serviceGroup.triggerGracefulShutdown()
            }
        } catch {
            try await httpClient.shutdown()
            throw error
        }
        try await httpClient.shutdown()
    }

    @Test func testUpgradeAfterNotUpgraded() async throws {
        let router = Router()
        router.get("/") { _, _ in
            "Helllo"
        }
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade { _, _, _ in
                .dontUpgrade
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
            }
            // perform upgrade
            try await client.execute(uri: "/test?this=that", method: .get, headers: [.upgrade: "websocket"]) { response in
                #expect(response.status == .temporaryRedirect)
                #expect(response.headers[.location] == "/test?this=that")
            }
            // check channel has been closed
            await #expect(throws: ChannelError.ioOnClosedChannel) {
                try await client.execute(uri: "/", method: .get)
            }
        }
    }
}
