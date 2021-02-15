import HummingbirdCore
import NIO
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    public func addWebSocketUpgrade(
        shouldUpgrade: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders> = { channel, _ in return channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        onUpgrade: @escaping (WebSocket) -> ()
    ) {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                let webSocket = WebSocket(channel: channel)
                onUpgrade(webSocket)
                return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket))
            }
        )
        self.httpChannelInitializer = HTTP1ChannelInitializer(upgraders: [upgrader])
    }
}
