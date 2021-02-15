import NIO
import NIOWebSocket

/// WebSocket channel handler. Sends WebSocket frames, receives and combines frames.
/// Code inspired from vapor/websocket-kit https://github.com/vapor/websocket-kit
/// and the WebSocket sample from swift-nio
/// https://github.com/apple/swift-nio/tree/main/Sources/NIOWebSocketClient
///
final class WebSocketHandler: ChannelDuplexHandler {
    typealias OutboundIn = WebSocketData
    typealias OutboundOut = WebSocketFrame
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = WebSocketData

    static let pingData: String = "Hummingbird"

    var webSocketFrameSequence: WebSocketFrameSequence?
    var waitingOnPong: Bool = false
    var pingInterval: TimeAmount? = nil
    
    /// Write bytebuffer as WebSocket frame
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard context.channel.isActive else { return }

        let buffer = unwrapOutboundIn(data)
        switch buffer {
        case .text(let string):
            let buffer = context.channel.allocator.buffer(string: string)
            send(context: context, buffer: buffer, opcode: .text, fin: true, promise: promise)
        case.binary(let buffer):
            send(context: context, buffer: buffer, opcode: .binary, fin: true, promise: promise)
        }
    }

    /// Read WebSocket frame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .pong:
            self.pong(context: context, frame: frame)
        case .ping:
            self.ping(context: context, frame: frame)
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
                self.close(context: context, code: .protocolError, promise: nil)
            }
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)

        default:
            break
        }

        if let frameSeq = self.webSocketFrameSequence, frame.fin {
            context.fireChannelRead(wrapInboundOut(frameSeq.result))
            self.webSocketFrameSequence = nil
        }
    }

    /// Send web socket frame to server
    private func send(
        context: ChannelHandlerContext,
        buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        let maskKey = makeMaskKey()
        let frame = WebSocketFrame(fin: fin, opcode: opcode, maskKey: maskKey, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
    }

    /// Send ping and setup task to check for pong and send new ping
    private func sendPingAndWait(context: ChannelHandlerContext) {
        guard context.channel.isActive, let pingInterval = pingInterval else {
            return
        }
        if waitingOnPong {
            // We never received a pong from our last ping, so the connection has timed out
            let promise = context.eventLoop.makePromise(of: Void.self)
            self.close(context: context, code: .unknown(1006), promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocket is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                context.channel.close(mode: .all, promise: nil)
            }

        } else {
            let buffer = context.channel.allocator.buffer(string: Self.pingData)
            self.send(context: context, buffer: buffer, opcode: .ping)
            _ = context.eventLoop.scheduleTask(in: pingInterval) {
                self.sendPingAndWait(context: context)
            }
        }
    }

    /// Respond to pong from server. Verify contents of pong and clear waitingOnPong flag
    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.unmaskedData
        guard let frameDataString = frameData.readString(length: Self.pingData.count),
              frameDataString == Self.pingData else {
            self.close(context: context, code: .goingAway, promise: nil)
            return
        }
        self.waitingOnPong = false
    }

    /// Respond to ping from server
    private func ping(context: ChannelHandlerContext, frame: WebSocketFrame) {
        if frame.fin {
            self.send(context: context, buffer: frame.unmaskedData, opcode: .pong, fin: true, promise: nil)
        } else {
            self.close(context: context, code: .protocolError, promise: nil)
        }
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. We're just going to close.
        self.isClosed = true
        context.close(promise: nil)
    }

    /// Make mask key to be used in WebSocket frame
    func makeMaskKey() -> WebSocketMaskingKey? {
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: 1...255) }
        return WebSocketMaskingKey(bytes)
    }

    /// Close websocket connection
    public func close(context: ChannelHandlerContext, code: WebSocketErrorCode = .goingAway, promise: EventLoopPromise<Void>?) {
        guard isClosed == false else {
            promise?.succeed(())
            return
        }
        self.isClosed = true

        let codeAsInt = UInt16(webSocketErrorCode: code)
        let codeToSend: WebSocketErrorCode
        if codeAsInt == 1005 || codeAsInt == 1006 {
            /// Code 1005 and 1006 are used to report errors to the application, but must never be sent over
            /// the wire (per https://tools.ietf.org/html/rfc6455#section-7.4)
            codeToSend = .normalClosure
        } else {
            codeToSend = code
        }

        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)
        self.send(context: context, buffer: buffer, opcode: .connectionClose, fin: true, promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            // we received a quiesce event. If we have any requests in progress we should
            // wait for them to finish
            close(context: context, promise: nil)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        close(context: context, code: .unknown(1006), promise: nil)

        // We always forward the error on to let others see it.
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let errorCode: WebSocketErrorCode
        if let error = error as? NIOWebSocketError {
            errorCode = WebSocketErrorCode(error)
        } else {
            errorCode = .unexpectedServerError
        }
        close(context: context, code: errorCode, promise: nil)

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


