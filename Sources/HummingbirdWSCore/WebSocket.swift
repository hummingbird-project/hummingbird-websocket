//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import Logging
import NIOCore
import NIOWebSocket

/// WebSocket object
public final class HBWebSocket: Sendable {
    public enum SocketType: Sendable {
        case client
        case server
    }

    private class AutoPingTaskManager {
        private var waitingOnPong: Bool
        private var pingData: ByteBuffer
        private var autoPingTask: Scheduled<Void>?

        init(channel: Channel) {
            self.waitingOnPong = false
            self.pingData = channel.allocator.buffer(capacity: 16)
            self.autoPingTask = nil
            channel.closeFuture.whenComplete { _ in
                self.shutdown()
            }
        }

        func shutdown() {
            self.autoPingTask?.cancel()
        }

        /// Send ping and setup task to check for pong and send new ping
        func initiateAutoPing(interval: TimeAmount, ws: HBWebSocket) {
            self.autoPingTask = ws.channel.eventLoop.scheduleTask(in: interval) {
                if self.waitingOnPong {
                    // We never received a pong from our last ping, so the connection has timed out
                    let promise = ws.channel.eventLoop.makePromise(of: Void.self)
                    ws.close(code: .goingAway, promise: promise)
                    promise.futureResult.whenComplete { _ in
                        // Usually, closing a WebSocket is done by sending the close frame and waiting
                        // for the peer to respond with their close frame. We are in a timeout situation,
                        // so the other side likely will never send the close frame. We just close the
                        // channel ourselves.
                        ws.channel.close(mode: .all, promise: nil)
                    }

                } else {
                    ws.sendPing().whenSuccess {
                        self.waitingOnPong = true
                        self.initiateAutoPing(interval: interval, ws: ws)
                    }
                }
            }
        }

        /// Respond to pong from client. Verify contents of pong and clear waitingOnPong flag
        func receivedPong(frame: WebSocketFrame, ws: HBWebSocket) {
            let frameData = frame.unmaskedData
            guard frameData == self.pingData else {
                ws.close(code: .goingAway, promise: nil)
                return
            }
            self.waitingOnPong = false
            ws.pongCallback.load(ordering: .relaxed).wrapped?(ws)
        }

        /// Send ping message
        /// - Parameter promise: promise that is completed when ping message has been sent
        func sendPing(ws: HBWebSocket, promise: EventLoopPromise<Void>?) {
            if self.waitingOnPong {
                promise?.succeed(())
                return
            }
            // creating random payload
            let random = (0..<16).map { _ in UInt8.random(in: 0...255) }
            self.pingData.clear()
            self.pingData.writeBytes(random)

            ws.send(buffer: self.pingData, opcode: .ping, promise: promise)
        }
    }

    public let channel: Channel
    @inlinable public var eventLoop: EventLoop {
        return self.channel.eventLoop
    }

    public typealias ReadCallback = @Sendable (WebSocketData, HBWebSocket) -> Void
    public typealias CloseCallback = @Sendable (HBWebSocket) -> Void
    public typealias PongCallback = @Sendable (HBWebSocket) -> Void

    // wrapper class for type that conforms to AtomicReference
    final class AtomicContainer<Value: Sendable>: AtomicReference, Sendable {
        let wrapped: Value

        init(_ value: Value) {
            self.wrapped = value
        }
    }

    let type: SocketType
    public let maxFrameSize: Int
    let extensions: [any HBWebSocketExtension]
    let logger: Logger
    private let autoPingManager: NIOLoopBound<AutoPingTaskManager>
    private let isClosed: ManagedAtomic<Bool>
    private let pongCallback: ManagedAtomic<AtomicContainer<PongCallback?>>
    private let readCallback: ManagedAtomic<AtomicContainer<ReadCallback?>>

    public init(channel: Channel, type: SocketType, maxFrameSize: Int = 1 << 14, extensions: [any HBWebSocketExtension] = [], logger: Logger) {
        self.channel = channel
        self.isClosed = .init(false)
        self.pongCallback = .init(.init(nil))
        self.readCallback = .init(.init(nil))
        self.autoPingManager = .init(.init(channel: channel), eventLoop: channel.eventLoop)
        self.type = type
        self.maxFrameSize = maxFrameSize
        self.extensions = extensions
        self.logger = logger.with(metadataKey: "hb_ws_id", value: .stringConvertible(Self.globalRequestID.loadThenWrappingIncrement(by: 1, ordering: .relaxed)))

        self.channel.closeFuture.whenComplete { _ in
            for ext in self.extensions {
                ext.shutdown()
            }
        }
    }

    /// Set callback to be called whenever WebSocket receives data
    @preconcurrency public func onRead(_ cb: @escaping ReadCallback) {
        self.readCallback.store(.init(cb), ordering: .relaxed)
    }

    /// Set callback to be called whenever WebSocket receives a pong
    @preconcurrency public func onPong(_ cb: @escaping PongCallback) {
        self.pongCallback.store(.init(cb), ordering: .relaxed)
    }

    /// Set callback to be called whenever WebSocket channel is closed
    @preconcurrency public func onClose(_ cb: @escaping CloseCallback) {
        self.channel.closeFuture.whenComplete { _ in
            cb(self)
        }
    }

    /// Write data to WebSocket
    /// - Parameter data: data to be written
    /// - Returns: future that is completed when data is written
    public func write(_ data: WebSocketData) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.write(data, promise: promise)
        return promise.futureResult
    }

    /// Write data to WebSocket
    /// - Parameters:
    ///   - data: Data to be written
    ///   - promise: promise that is completed when data has been sent
    public func write(_ data: WebSocketData, promise: EventLoopPromise<Void>?) {
        switch data {
        case .text(let string):
            let buffer = self.channel.allocator.buffer(string: string)
            self.send(buffer: buffer, opcode: .text, fin: true, promise: promise)
        case .binary(let buffer):
            self.send(buffer: buffer, opcode: .binary, fin: true, promise: promise)
        }
    }

    /// Close websocket connection
    /// - Parameter code:
    /// - Returns: future that is complete once close message is sent
    public func close(code: WebSocketErrorCode = .normalClosure) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.close(code: code, promise: promise)
        return promise.futureResult
    }

    /// Close websocket connection
    /// - Parameters:
    ///   - code: Close reason
    ///   - promise: promise that is completed when close has been sent
    public func close(code: WebSocketErrorCode = .normalClosure, promise: EventLoopPromise<Void>?) {
        guard self.isClosed.load(ordering: .relaxed) == false else {
            promise?.succeed(())
            return
        }
        self.isClosed.store(true, ordering: .relaxed)

        self.logger.debug("Closing WebSocket")

        var buffer = self.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        self.send(buffer: buffer, opcode: .connectionClose, fin: true, promise: promise)
    }

    /// Send ping message
    /// - Returns: future that is complete when ping message is sent
    public func sendPing() -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.sendPing(promise: promise)
        return promise.futureResult
    }

    /// Send ping message
    /// - Parameter promise: promise that is completed when ping message has been sent
    public func sendPing(promise: EventLoopPromise<Void>?) {
        if self.channel.eventLoop.inEventLoop {
            self.autoPingManager.value.sendPing(ws: self, promise: promise)
        } else {
            self.channel.eventLoop.execute {
                self.autoPingManager.value.sendPing(ws: self, promise: promise)
            }
        }
    }

    /// Send an unsolicited Pong message
    ///
    /// This can be used as a unidirectional heartbeat.
    /// See [RFC6455](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.5.3)
    /// - Parameter promise: promise that is completed when pong message has been sent
    public func sendPong(_ buffer: ByteBuffer, promise: EventLoopPromise<Void>?) {
        self.channel.eventLoop.execute {
            self.send(buffer: buffer, opcode: .pong)
        }
    }

    /// Send ping and setup task to check for pong and send new ping
    public func initiateAutoPing(interval: TimeAmount) {
        guard self.channel.isActive else {
            return
        }
        if self.channel.eventLoop.inEventLoop {
            self.autoPingManager.value.initiateAutoPing(interval: interval, ws: self)
        } else {
            self.channel.eventLoop.execute {
                self.autoPingManager.value.initiateAutoPing(interval: interval, ws: self)
            }
        }
    }

    func read(_ frameSequence: WebSocketFrameSequence) {
        var frame = frameSequence.collapsed
        self.logger.trace("Read: \(frame.traceDescription)")
        do {
            for ext in self.extensions.reversed() {
                frame = try ext.processReceivedFrame(frame, ws: self)
            }
        } catch {
            self.logger.debug("Closing as we received invalid frame data")
            self.close(code: .unacceptableData, promise: nil)
        }
        if let webSocketData = WebSocketData(frame: frame) {
            self.readCallback.load(ordering: .relaxed).wrapped?(webSocketData, self)
        }
    }

    /// Send web socket frame to server
    func send(
        buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        // make sure we are sending on the channel EventLoop
        if self.channel.eventLoop.inEventLoop {
            self._send(buffer: buffer, opcode: opcode, fin: fin, promise: promise)
        } else {
            self.channel.eventLoop.execute {
                self._send(buffer: buffer, opcode: opcode, fin: fin, promise: promise)
            }
        }
    }

    private func _send(
        buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool,
        promise: EventLoopPromise<Void>?
    ) {
        var frame = WebSocketFrame(fin: fin, opcode: opcode, data: buffer)
        do {
            for ext in self.extensions {
                frame = try ext.processFrameToSend(frame, ws: self)
            }
        } catch {
            self.logger.debug("Closing as we failed to generate valid frame data")
            self.close(code: .unexpectedServerError, promise: nil)
        }
        self.logger.trace("Sent: \(frame.traceDescription)")
        frame.maskKey = self.makeMaskKey()
        self.channel.writeAndFlush(frame, promise: promise)
    }

    /// Respond to pong from client. Verify contents of pong and clear waitingOnPong flag
    func receivedPong(frame: WebSocketFrame) {
        self.logger.trace("Received pong")
        self.autoPingManager.value.receivedPong(frame: frame, ws: self)
    }

    /// Respond to ping from client
    func receivedPing(frame: WebSocketFrame) {
        self.logger.trace("Received ping")
        if frame.fin {
            self.send(buffer: frame.unmaskedData, opcode: .pong, fin: true, promise: nil)
        } else {
            self.close(code: .protocolError, promise: nil)
        }
    }

    func receivedClose(frame: WebSocketFrame) {
        self.logger.trace("Received close")
        // Handle a received close frame. We're just going to close.
        self.isClosed.store(true, ordering: .relaxed)
        self.channel.close(promise: nil)
    }

    func errorCaught(_ error: Error) {
        let errorCode: WebSocketErrorCode
        if let error = error as? NIOWebSocketError {
            errorCode = WebSocketErrorCode(error)
        } else {
            errorCode = .unexpectedServerError
        }
        self.close(code: errorCode, promise: nil)
    }

    /// Make mask key to be used in WebSocket frame
    private func makeMaskKey() -> WebSocketMaskingKey? {
        guard self.type == .client else { return nil }
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: .min ... .max) }
        return WebSocketMaskingKey(bytes)
    }

    private static let globalRequestID = ManagedAtomic(0)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension HBWebSocket {
    /// Write data to WebSocket
    /// - Parameters:
    ///   - data: Data to be written
    public func write(_ data: WebSocketData) async throws {
        return try await self.write(data).get()
    }

    /// Close websocket connection
    /// - Parameter code: reason for closing socket
    public func close(code: WebSocketErrorCode = .normalClosure) async throws {
        return try await self.close(code: code).get()
    }

    /// Send ping message
    public func sendPing() async throws {
        return try await self.sendPing().get()
    }

    /// Return stream of web socket data
    ///
    /// This uses the `onRead`` and `onClose` functions so should not be used
    /// at the same time as these functions.
    /// - Returns: Web socket data stream
    public func readStream() -> AsyncStream<WebSocketData> {
        return AsyncStream { cont in
            self.onRead { data, _ in
                cont.yield(data)
            }
            self.onClose { _ in
                cont.finish()
            }
        }
    }
}

/// Extend WebSocketFrame to provide debug description for trace logs
extension WebSocketFrame {
    fileprivate var traceDescription: String {
        var flags: [String] = []
        if self.fin {
            flags.append("FIN")
        }
        if self.rsv1 {
            flags.append("RSV1")
        }
        if self.rsv2 {
            flags.append("RSV2")
        }
        if self.rsv3 {
            flags.append("RSV3")
        }

        return "WebSocketFrame(\(self.opcode), flags: \(flags.joined(separator: ",")), data: \(self.data.debugDescription))"
    }
}

extension Logger {
    /// Create new Logger with additional metadata value
    /// - Parameters:
    ///   - metadataKey: Metadata key
    ///   - value: Metadata value
    /// - Returns: Logger
    func with(metadataKey: String, value: MetadataValue) -> Logger {
        var logger = self
        logger[metadataKey: metadataKey] = value
        return logger
    }
}
