import Hummingbird
import NIO
import NIOHTTP1

/// The HTTP handler to be used to initiate the request.
/// This initial request will be adapted by the WebSocket upgrader to contain the upgrade header parameters.
/// Channel read will only be called if the upgrade fails.
final class WebSocketInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    let host: String
    let urlPath: String
    let headers: HTTPHeaders
    let upgradePromise: EventLoopPromise<Void>

    init(url: HBWebSocketClient.SplitURL, headers: HTTPHeaders = [:], upgradePromise: EventLoopPromise<Void>) throws {
        self.host = url.hostHeader
        self.urlPath = url.pathQuery
        self.headers = headers
        self.upgradePromise = upgradePromise
    }

    public func channelActive(context: ChannelHandlerContext) {
        // We are connected. It's time to send the message to the server to initialize the upgrade dance.
        var headers = self.headers
        headers.add(name: "content-length", value: "0")
        headers.replaceOrAdd(name: "host", value: self.host)

        let requestHead = HTTPRequestHead(
            version: HTTPVersion(major: 1, minor: 1),
            method: .GET,
            uri: urlPath,
            headers: headers
        )

        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer()))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let clientResponse = self.unwrapInboundIn(data)

        switch clientResponse {
        case .head:
            self.upgradePromise.fail(HBWebSocketClient.Error.websocketUpgradeFailed)
        case .body:
            break
        case .end:
            context.close(promise: nil)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.upgradePromise.fail(error)
        // As we are not really interested getting notified on success or failure
        // we just pass nil as promise to reduce allocations.
        context.close(promise: nil)
    }
}
