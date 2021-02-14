import HummingbirdCore
import NIO
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    public func addWebSocketUpgrade() {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                print("Should I upgrade")
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                print("Upgraded")
                return channel.pipeline.addHandlers([WebSocketHandler(), WebSocketEchoHandler()]).map {
                    print(channel.pipeline)
                }
            }
        )
        self.httpChannelInitializer = HTTP1ChannelInitializer(upgraders: [upgrader])
    }
}
