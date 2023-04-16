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

final class HummingbirdWebSocketTests: XCTestCase {
    static var eventLoopGroup: EventLoopGroup!

    override class func setUp() {
        Self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override class func tearDown() {
        XCTAssertNoThrow(try Self.eventLoopGroup.syncShutdownGracefully())
    }

    enum Error: Swift.Error {
        case unexpectedClose
    }

    struct TimeoutPromise {
        let task: Scheduled<Void>
        let promise: EventLoopPromise<Void>

        init(eventLoop: EventLoop, timeout: TimeAmount) {
            let promise = eventLoop.makePromise(of: Void.self)
            self.promise = promise
            self.task = eventLoop.scheduleTask(in: timeout) { promise.fail(ChannelError.connectTimeout(timeout)) }
        }

        func succeed() {
            self.promise.succeed(())
        }

        func fail(_ error: Error) {
            self.promise.fail(error)
        }

        func wait() throws {
            try self.promise.futureResult.wait()
            self.task.cancel()
        }
    }

    func createRandomBuffer(size: Int) -> ByteBuffer {
        // create buffer
        var data = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            data[i] = UInt8.random(in: 0...255)
        }
        return ByteBuffer(bytes: data)
    }

    func setupClientAndServer(
        onServer: @escaping (HBWebSocket) -> Void,
        onClient: @escaping (HBWebSocket) -> Void
    ) throws -> HBApplication {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)), eventLoopGroupProvider: .shared(Self.eventLoopGroup))
        // add HTTP to WebSocket upgrade
        app.ws.addUpgrade()
        // on websocket connect.
        app.ws.on("/test", onUpgrade: { _, ws in
            onServer(ws)
        })
        try app.start()

        let eventLoop = app.eventLoopGroup.next()
        HBWebSocketClient.connect(url: "ws://localhost:8080/test", configuration: .init(), on: eventLoop).whenComplete { result in
            switch result {
            case .failure(let error):
                XCTFail("\(error)")
            case .success(let ws):
                onClient(ws)
            }
        }
        return app
    }

    func setupClientAndServer(onServer: @escaping (HBWebSocket) async throws -> Void, onClient: @escaping (HBWebSocket) async throws -> Void) async throws -> HBApplication {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
        // add HTTP to WebSocket upgrade
        app.ws.addUpgrade()
        // on websocket connect.
        app.ws.on("/test", onUpgrade: { _, ws in
            try await onServer(ws)
            return .ok
        })
        try app.start()

        let eventLoop = app.eventLoopGroup.next()
        let ws = try await HBWebSocketClient.connect(url: "ws://localhost:8080/test", configuration: .init(), on: eventLoop)
        try await onClient(ws)
        return app
    }

    func testClientAndServerConnection() throws {
        var serverHello: Bool = false
        var clientHello: Bool = false
        let promise = TimeoutPromise(eventLoop: Self.eventLoopGroup.next(), timeout: .seconds(5))
        let app = try self.setupClientAndServer(
            onServer: { ws in
                ws.onRead { data, ws in
                    XCTAssertEqual(data, .text("Hello"))
                    serverHello = true
                    ws.write(.text("Hello back"), promise: nil)
                }
            },
            onClient: { ws in
                ws.onRead { data, _ in
                    XCTAssertEqual(data, .text("Hello back"))
                    clientHello = true
                    promise.succeed()
                }
                ws.write(.text("Hello"), promise: nil)
            }
        )
        defer { app.stop() }

        try promise.wait()
        XCTAssertTrue(serverHello)
        XCTAssertTrue(clientHello)
    }

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

        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
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
            url: "ws://localhost:8080/test",
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

        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
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
            url: "ws://localhost:8080/test",
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
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
        app.router.get("/test") { _ in
            "hello"
        }
        try app.start()
        defer { app.stop() }

        let eventLoop = Self.eventLoopGroup.next()
        let clientWS = HBWebSocketClient.connect(url: "ws://localhost:8080/test", configuration: .init(), on: eventLoop)
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
        let clientWS = HBWebSocketClient.connect(url: "http://localhost:8080", configuration: .init(), on: eventLoop)
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

    func testQuery() throws {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
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
        let wsFuture = HBWebSocketClient.connect(url: "ws://localhost:8080/test?connect", configuration: .init(), on: eventLoop)
        _ = try wsFuture.wait()
    }

    func testAdditionalHeaders() throws {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
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
            url: "ws://localhost:8080/test",
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
    }
}
