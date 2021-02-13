import HummingbirdCore
import NIO
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    public func addWebSocketUpgrade() {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                channel.pipeline.addHandlers([WebSocketHandler(), WebSocketEchoHandler()])
            }
        )
        self.httpChannelInitializer = HTTP1ChannelInitializer(upgraders: [upgrader])
    }
}
