import NIO
import NIOWebSocket

/// WebSocket channel handler. Sends WebSocket frames, receives and combines frames.
/// Code inspired from vapor/websocket-kit https://github.com/vapor/websocket-kit
/// and the WebSocket sample from swift-nio
/// https://github.com/apple/swift-nio/tree/main/Sources/NIOWebSocketClient
///
final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    var webSocketFrameSequence: WebSocketFrameSequence?
    var webSocket: HBWebSocket
    
    init(webSocket: HBWebSocket) {
        self.webSocket = webSocket
    }
    
    /// Read WebSocket frame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .pong:
            webSocket.pong(frame: frame)
        case .ping:
            webSocket.ping(frame: frame)
        case .text:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                var frameSeq = WebSocketFrameSequence(type: .text)
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            }
        case .binary:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                var frameSeq = WebSocketFrameSequence(type: .binary)
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            }
        case .continuation:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                webSocket.close(code: .protocolError, promise: nil)
            }
        case .connectionClose:
            webSocket.receivedClose(frame: frame)

        default:
            break
        }

        if let frameSeq = self.webSocketFrameSequence, frame.fin {
            webSocket.read(frameSeq.result)
            self.webSocketFrameSequence = nil
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            // we received a quiesce event. If we have any requests in progress we should
            // wait for them to finish
            webSocket.close(promise: nil)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        webSocket.close(code: .unknown(1006), promise: nil)

        // We always forward the error on to let others see it.
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        webSocket.errorCaught(error)

        // We always forward the error on to let others see it.
        context.fireErrorCaught(error)
    }

    private var isClosed: Bool = false
}

extension WebSocketErrorCode {
    init(_ error: NIOWebSocketError) {
        switch error {
        case .invalidFrameLength:
            self = .messageTooLarge
        case .fragmentedControlFrame,
             .multiByteControlFrameLength:
            self = .protocolError
        }
    }
}


