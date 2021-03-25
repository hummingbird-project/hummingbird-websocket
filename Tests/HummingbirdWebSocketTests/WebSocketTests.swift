import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import NIO
import XCTest

final class HummingbirdWebSocketTests: XCTestCase {

    func testClientAndServerConnection() throws {
        var upgrade: Bool = false
        var serverHello: Bool = false
        var clientHello: Bool = false
        let app = HBApplication(configuration: .init(address: .hostname(port: 8080)))
        // add HTTP to WebSocket upgrade
        app.ws.addUpgrade()
        // on websocket connect.
        app.ws.on(
            "/test",
            onUpgrade: { request, ws in
                upgrade = true
                ws.onRead { data, ws in
                    XCTAssertEqual(data, .text("Hello"))
                    serverHello = true
                    ws.write(.text("Hello back"))
                }
            }
        )
        app.start()
        defer { app.stop() }

        let eventLoop = app.eventLoopGroup.next()
        let writePromise = eventLoop.makePromise(of: Void.self)

        do {
            let clientWS = try HBWebSocketClient.connect(url: "ws://localhost:8080/test", configuration: .init(), on: eventLoop).wait()
            clientWS.onRead { data, ws in
                XCTAssertEqual(data, .text("Hello back"))
                clientHello = true
                writePromise.succeed(Void())
            }
            clientWS.write(.text("Hello"), promise: nil)
        } catch {
            writePromise.fail(error)
        }
        try writePromise.futureResult.wait()
        XCTAssertTrue(upgrade)
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
            clientWS.onRead { data, ws in
                XCTAssertEqual(data, .text("Hello"))
                writePromise.succeed(Void())
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
            clientWS.onRead { data, ws in
                XCTAssertEqual(data, .text("Hello"))
                writePromise.succeed(Void())
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
}

