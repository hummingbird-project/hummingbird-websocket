import AsyncHTTPClient
import HummingbirdCore
@testable import HummingbirdWebSocket
import NIO
import XCTest

final class HummingbirdWebSocketTests: XCTestCase {
    static var eventLoopGroup: EventLoopGroup!
    static var httpClient: HTTPClient!

    override class func setUp() {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.eventLoopGroup))
    }

    override class func tearDown() {
        XCTAssertNoThrow(try self.httpClient.syncShutdown())
        XCTAssertNoThrow(try self.eventLoopGroup.syncShutdownGracefully())
    }

    func testConnect() {
        struct HelloResponder: HBHTTPResponder {
            func respond(to request: HBHTTPRequest, context: ChannelHandlerContext) -> EventLoopFuture<HBHTTPResponse> {
                let response = HBHTTPResponse(
                    head: .init(version: .init(major: 1, minor: 1), status: .ok),
                    body: .byteBuffer(context.channel.allocator.buffer(string: "Hello"))
                )
                return context.eventLoop.makeSucceededFuture(response)
            }
        }
        let server = HBHTTPServer(group: Self.eventLoopGroup, configuration: .init(address: .hostname(port: 8080)))
        XCTAssertNoThrow(try server.start(responder: HelloResponder()).wait())
        defer { XCTAssertNoThrow(try server.stop().wait()) }

        let request = try! HTTPClient.Request(
            url: "http://localhost:\(server.configuration.address.port!)/"
        )
        let future = Self.httpClient.execute(request: request).flatMapThrowing { response in
            var body = try XCTUnwrap(response.body)
            XCTAssertEqual(body.readString(length: body.readableBytes), "Hello")
        }
        XCTAssertNoThrow(try future.wait())
    }

}
