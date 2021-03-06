import NIO
import NIOWebSocket

/// WebSocket channel handler. Passes web socket frames onto `HBWebSocket` object.
///
/// The handler combines fragmented frames together before passing them onto
/// the `HBWebSocket`.
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
            self.webSocket.pong(frame: frame)
        case .ping:
            self.webSocket.ping(frame: frame)
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
                self.webSocket.close(code: .protocolError, promise: nil)
            }
        case .connectionClose:
            self.webSocket.receivedClose(frame: frame)

        default:
            break
        }

        if let frameSeq = self.webSocketFrameSequence, frame.fin {
            self.webSocket.read(frameSeq.result)
            self.webSocketFrameSequence = nil
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            // we received a quiesce event so should close the channel.
            self.webSocket.close(promise: nil)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.webSocket.close(code: .goingAway, promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.webSocket.errorCaught(error)
        context.fireErrorCaught(error)
    }
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
