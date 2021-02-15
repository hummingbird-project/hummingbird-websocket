import HummingbirdCore
import NIO
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    /// Add WebSocket upgrade option
    /// - Parameters:
    ///   - shouldUpgrade: Closure returning whether upgrade should happen
    ///   - onUpgrade: Closure called once upgrade has happened. Includes the `HBWebSocket` created to service the WebSocket connection.
    public func addWebSocketUpgrade(
        shouldUpgrade: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> = { channel, _ in return channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        onUpgrade: @escaping (HBWebSocket, HTTPRequestHead) -> Void
    ) {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                return shouldUpgrade(channel, head)
            },
            upgradePipelineHandler: { (channel: Channel, head: HTTPRequestHead) in
                let webSocket = HBWebSocket(channel: channel, type: .server)
                onUpgrade(webSocket, head)
                return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket))
            }
        )
        self.httpChannelInitializer = HTTP1ChannelInitializer(upgraders: [upgrader])
    }
}
