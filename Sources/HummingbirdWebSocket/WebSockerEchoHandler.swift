import NIO

final class WebSocketEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    func handlerAdded(context: ChannelHandlerContext) {
        context.writeAndFlush(self.wrapOutboundOut(context.channel.allocator.buffer(string: "Hello")), promise: nil)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        print(String(buffer: input))
        context.writeAndFlush(self.wrapOutboundOut(input), promise: nil)
    }
}
