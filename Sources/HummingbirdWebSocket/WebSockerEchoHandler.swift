import NIO

final class WebSocketEchoHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketData
    typealias OutboundOut = WebSocketData
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        context.writeAndFlush(self.wrapOutboundOut(input), promise: nil)
    }
}
