import HummingbirdCore
import NIO
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    public func addWebSocketUpgrade(
        shouldUpgrade: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders> = { channel, _ in return channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        onUpgrade: @escaping (HBWebSocket, HTTPRequestHead) -> ()
    ) {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: Channel, head: HTTPRequestHead) in
                let webSocket = HBWebSocket(channel: channel)
                onUpgrade(webSocket, head)
                return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket))
            }
        )
        self.httpChannelInitializer = HTTP1ChannelInitializer(upgraders: [upgrader])
    }
}
