import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import NIO
import XCTest

final class HummingbirdWebSocketTests: XCTestCase {
    func setupClientAndServer(onServer: @escaping (HBWebSocket)->(), onClient: @escaping (HBWebSocket)->()) -> HBApplication {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
        // add HTTP to WebSocket upgrade
        app.ws.addUpgrade()
        // on websocket connect.
        app.ws.on("/test", onUpgrade: { _, ws in
            onServer(ws)
        })
        app.start()

        let eventLoop = app.eventLoopGroup.next()
        HBWebSocketClient.connect(url: "ws://localhost:8080/test", configuration: .init(), on: eventLoop).whenComplete { result in
            switch result {
            case .failure(let error):
                XCTFail("\(error)")
                break
            case .success(let ws):
                onClient(ws)
            }
        }
        return app
    }

    func testClientAndServerConnection() throws {
        var serverHello: Bool = false
        var clientHello: Bool = false
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let writePromise = elg.next().makePromise(of: Void.self)

        let app = setupClientAndServer(
            onServer: { ws in
                ws.onRead { data, ws in
                    XCTAssertEqual(data, .text("Hello"))
                    serverHello = true
                    ws.write(.text("Hello back"))
                }
            },
            onClient: { ws in
                ws.onRead { data, _ in
                    XCTAssertEqual(data, .text("Hello back"))
                    clientHello = true
                    writePromise.succeed(())
                }
                ws.write(.text("Hello"), promise: nil)
            }
        )
        defer { app.stop() }

        try writePromise.futureResult.wait()
        XCTAssertTrue(serverHello)
        XCTAssertTrue(clientHello)
    }

    func testClient() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? elg.syncShutdownGracefully() }

        let eventLoop = elg.next()
        let writePromise = eventLoop.makePromise(of: Void.self)

        do {
            let clientWS = try HBWebSocketClient.connect(url: "ws://echo.websocket.org", configuration: .init(), on: eventLoop).wait()
            clientWS.onRead { data, _ in
                XCTAssertEqual(data, .text("Hello"))
                writePromise.succeed(())
            }
            clientWS.write(.text("Hello"), promise: nil)
        } catch {
            writePromise.fail(error)
        }
        try writePromise.futureResult.wait()
    }

    func testTLS() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? elg.syncShutdownGracefully() }

        let eventLoop = elg.next()
        let writePromise = eventLoop.makePromise(of: Void.self)

        do {
            let clientWS = try HBWebSocketClient.connect(url: "wss://echo.websocket.org", configuration: .init(), on: eventLoop).wait()
            clientWS.onRead { data, _ in
                XCTAssertEqual(data, .text("Hello"))
                writePromise.succeed(())
            }
            clientWS.write(.text("Hello"), promise: nil)
        } catch {
            writePromise.fail(error)
        }
        try writePromise.futureResult.wait()
    }

    func testNotWebSocket() throws {
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
        app.router.get("/test") { _ in
            "hello"
        }
        app.start()
        defer { app.stop() }

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? elg.syncShutdownGracefully() }
        let eventLoop = elg.next()
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
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? elg.syncShutdownGracefully() }
        let eventLoop = elg.next()
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
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let promise = elg.next().makePromise(of: Void.self)

        let app = setupClientAndServer(
            onServer: { ws in
                ws.onClose { ws in
                    promise.succeed(())
                }
            },
            onClient: { ws in
                ws.write(.text("Hello"), promise: nil)
                ws.close(code: .normalClosure, promise: nil)
            }
        )
        defer { app.stop() }

        try promise.futureResult.wait()
    }

    func testServerCloseConnection() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let promise = elg.next().makePromise(of: Void.self)

        let app = setupClientAndServer(
            onServer: { ws in
                ws.onRead { data, ws in
                    XCTAssertEqual(data, .text("Hello"))
                    ws.close(code: .normalClosure, promise: nil)
                }
            },
            onClient: { ws in
                ws.onClose { ws in
                    promise.succeed(())
                }
                ws.write(.text("Hello"), promise: nil)
            }
        )
        defer { app.stop() }

        try promise.futureResult.wait()
    }

    func testPingPong() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let promise = elg.next().makePromise(of: Void.self)

        let app = setupClientAndServer(
            onServer: { ws in
            },
            onClient: { ws in
                ws.onPong { ws in
                    promise.succeed(())
                }
                ws.sendPing(promise: nil)
            }
        )
        defer { app.stop() }

        try promise.futureResult.wait()
    }

    func testAutoPing() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let promise = elg.next().makePromise(of: Void.self)
        var count = 0

        let app = setupClientAndServer(
            onServer: { ws in
                ws.initiateAutoPing(interval: .seconds(5))
                ws.onPong { ws in
                    count += 1
                    // wait for second pong, meaning auto ping caught the first one
                    if count == 2 {
                        promise.succeed(())
                    }
                }
            },
            onClient: { ws in
            }
        )
        defer { app.stop() }

        try promise.futureResult.wait()
    }
}
