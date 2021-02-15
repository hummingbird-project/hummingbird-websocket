import HummingbirdCore
import NIO
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    public func addWebSocketUpgrade(_ onCreate: @escaping (WebSocket) -> ()) {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                let webSocket = WebSocket(channel: channel)
                onCreate(webSocket)
                return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket))
            }
        )
        self.httpChannelInitializer = HTTP1ChannelInitializer(upgraders: [upgrader])
    }
}
