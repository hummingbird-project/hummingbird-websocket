import NIO
import NIOWebSocket

/// WebSocket object
public final class HBWebSocket {
    enum SocketType {
        case client
        case server
    }
    public var channel: Channel
    let type: SocketType
    
    var waitingOnPong: Bool = false
    var pingData: ByteBuffer

    init(channel: Channel, type: SocketType) {
        self.channel = channel
        self.isClosed = false
        self.readCallback = nil
        self.pingData = channel.allocator.buffer(capacity: 16)
        self.type = type
    }

    /// Set callback to be called whenever WebSocket receives data
    public func onRead(_ cb: @escaping ReadCallback) {
        self.readCallback = cb
    }

    /// Set callback to be called whenever WebSocket channel is closed
    public func onClose(_ cb: @escaping CloseCallback) {
        channel.closeFuture.whenComplete { _ in
            cb(self)
        }
    }

    /// Write data to WebSocket
    /// - Parameters:
    ///   - data: Data to be written
    ///   - promise:promise that is completed when data has been sent
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
    /// - Parameters:
    ///   - code: Close reason
    ///   - promise: promise that is completed when close has been sent
    public func close(code: WebSocketErrorCode = .goingAway, promise: EventLoopPromise<Void>?) {
        guard isClosed == false else {
            promise?.succeed(())
            return
        }
        self.isClosed = true

        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
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
            self.close(code: .goingAway, promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocket is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                self.channel.close(mode: .all, promise: nil)
            }

        } else {
            // creating random payload
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
        guard frameData == pingData else {
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
        guard type == .client else { return nil }
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: 1...255) }
        return WebSocketMaskingKey(bytes)
    }

    public typealias ReadCallback = (WebSocketData, HBWebSocket) -> ()
    public typealias CloseCallback = (HBWebSocket) -> ()

    private var readCallback: ReadCallback?
    private var isClosed: Bool = false
}

