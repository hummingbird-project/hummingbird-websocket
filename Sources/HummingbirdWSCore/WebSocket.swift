import NIO
import NIOWebSocket

public final class HBWebSocket {
    public var channel: Channel
    
    var waitingOnPong: Bool = false
    var pingData: ByteBuffer

    init(channel: Channel) {
        self.channel = channel
        self.isClosed = false
        self.readCallback = nil
        self.pingData = channel.allocator.buffer(capacity: 16)
    }
    
    public func onRead(_ cb: @escaping ReadCallback) {
        self.readCallback = cb
    }

    public func write(_ data: WebSocketData, promise: EventLoopPromise<Void>? = nil) {
        switch data {
        case .text(let string):
            let buffer = self.channel.allocator.buffer(string: string)
            self.send(buffer: buffer, opcode: .text, fin: true, promise: promise)
        case.binary(let buffer):
            self.send(buffer: buffer, opcode: .binary, fin: true, promise: promise)
        }
    }
    
    /// Close websocket connection
    public func close(code: WebSocketErrorCode = .goingAway, promise: EventLoopPromise<Void>?) {
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

        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)
        self.send(buffer: buffer, opcode: .connectionClose, fin: true, promise: promise)
    }

    /// Send ping and setup task to check for pong and send new ping
    public func initiateAutoPing(interval: TimeAmount) {
        guard channel.isActive else {
            return
        }
        if waitingOnPong {
            // We never received a pong from our last ping, so the connection has timed out
            let promise = channel.eventLoop.makePromise(of: Void.self)
            self.close(code: .unknown(1006), promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocket is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                self.channel.close(mode: .all, promise: nil)
            }

        } else {
            let random = (0..<16).map { _ in UInt8.random(in: 0...255)}
            self.pingData.clear()
            self.pingData.writeBytes(random)
            self.send(buffer: self.pingData, opcode: .ping)
            self.waitingOnPong = true
            _ = channel.eventLoop.scheduleTask(in: interval) {
                self.initiateAutoPing(interval: interval)
            }
        }
    }

    func read(_ data: WebSocketData) {
        readCallback?(data, self)
    }
    
    /// Send web socket frame to server
    private func send(
        buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        let maskKey = makeMaskKey()
        let frame = WebSocketFrame(fin: fin, opcode: opcode, maskKey: maskKey, data: buffer)
        self.channel.writeAndFlush(frame, promise: promise)
    }

    /// Respond to pong from client. Verify contents of pong and clear waitingOnPong flag
    func pong(frame: WebSocketFrame) {
        let frameData = frame.unmaskedData
        guard /*let pingData = self.pingData,
              let frameDataString = frameData.readString(length: pingData.count),*/
              frameData == pingData else {
            self.close(code: .goingAway, promise: nil)
            return
        }
        self.waitingOnPong = false
    }

    /// Respond to ping from client
    func ping(frame: WebSocketFrame) {
        if frame.fin {
            self.send(buffer: frame.unmaskedData, opcode: .pong, fin: true, promise: nil)
        } else {
            self.close(code: .protocolError, promise: nil)
        }
    }

    func receivedClose(frame: WebSocketFrame) {
        // Handle a received close frame. We're just going to close.
        self.isClosed = true
        channel.close(promise: nil)
    }

    func errorCaught(_ error: Error) {
        let errorCode: WebSocketErrorCode
        if let error = error as? NIOWebSocketError {
            errorCode = WebSocketErrorCode(error)
        } else {
            errorCode = .unexpectedServerError
        }
        close(code: errorCode, promise: nil)
    }
    
    /// Make mask key to be used in WebSocket frame
    private func makeMaskKey() -> WebSocketMaskingKey? {
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: 1...255) }
        return WebSocketMaskingKey(bytes)
    }

    public typealias ReadCallback = (WebSocketData, HBWebSocket) -> ()
    
    private var readCallback: ReadCallback?
    private var isClosed: Bool = false
}

