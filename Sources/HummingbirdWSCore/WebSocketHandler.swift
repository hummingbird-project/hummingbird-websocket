//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023-2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import NIOWebSocket
import ServiceLifecycle

/// WebSocket type
package enum WebSocketType: Sendable {
    case client
    case server
}

/// Automatic ping setup
public struct AutoPingSetup: Sendable {
    enum Internal {
        case disabled
        case enabled(timePeriod: Duration)
    }

    internal let value: Internal
    internal init(_ value: Internal) {
        self.value = value
    }

    /// disable auto ping
    public static var disabled: Self { .init(.disabled) }
    /// send ping with fixed period
    public static func enabled(timePeriod: Duration) -> Self { .init(.enabled(timePeriod: timePeriod)) }
}

/// Handler processing raw WebSocket packets.
///
/// Manages ping, pong and close messages. Collates data and text messages into final frame
/// and passes them onto the ``WebSocketDataHandler`` data handler setup by the user.
package actor WebSocketHandler {
    enum InternalError: Error {
        case close(WebSocketErrorCode)
    }

    enum CloseState {
        case open
        case closing
        case closed(WebSocketErrorCode?)
    }

    package struct Configuration {
        let extensions: [any WebSocketExtension]
        let autoPing: AutoPingSetup

        package init(extensions: [any WebSocketExtension], autoPing: AutoPingSetup) {
            self.extensions = extensions
            self.autoPing = autoPing
        }
    }

    static let pingDataSize = 16
    var outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    let type: WebSocketType
    let configuration: Configuration
    let context: BasicWebSocketContext
    var pingData: ByteBuffer
    var pingTime: ContinuousClock.Instant = .now
    var closeState: CloseState

    private init(
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        type: WebSocketType,
        configuration: Configuration,
        context: some WebSocketContext
    ) {
        self.outbound = outbound
        self.type = type
        self.configuration = configuration
        self.context = .init(allocator: context.allocator, logger: context.logger)
        self.pingData = ByteBufferAllocator().buffer(capacity: Self.pingDataSize)
        self.closeState = .open
    }

    package static func handle<Context: WebSocketContext>(
        type: WebSocketType,
        configuration: Configuration,
        asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        context: Context,
        handler: @escaping WebSocketDataHandler<Context>
    ) async throws -> WebSocketErrorCode? {
        defer {
            context.logger.debug("Closed WebSocket")
        }
        let rt = try await asyncChannel.executeThenClose { inbound, outbound in
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: WebSocketErrorCode.self) { group in
                    let webSocketHandler = Self(outbound: outbound, type: type, configuration: configuration, context: context)
                    if case .enabled(let period) = configuration.autoPing.value {
                        /// Add task sending ping frames every so often and verifying a pong frame was sent back
                        group.addTask {
                            var waitTime = period
                            while true {
                                try await Task.sleep(for: waitTime)
                                if let timeSinceLastPing = await webSocketHandler.getTimeSinceLastWaitingPing() {
                                    // if time is less than timeout value, set wait time to when it would timeout
                                    // and re-run loop
                                    if timeSinceLastPing < period {
                                        waitTime = period - timeSinceLastPing
                                        continue
                                    } else {
                                        try await asyncChannel.channel.close(mode: .input)
                                        return .goingAway
                                    }
                                }
                                try await webSocketHandler.ping()
                                waitTime = period
                            }
                        }
                    }
                    let rt = try await webSocketHandler.handle(inbound: inbound, outbound: outbound, handler: handler, context: context)
                    group.cancelAll()
                    return rt
                }
            } onCancel: {
                Task {
                    try await asyncChannel.channel.close(mode: .input)
                }
            }
        }
        return rt
    }

    func handle<Context: WebSocketContext>(
        inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        handler: @escaping WebSocketDataHandler<Context>,
        context: Context
    ) async throws -> WebSocketErrorCode? {
        let webSocketOutbound = WebSocketOutboundWriter(handler: self)
        var inboundIterator = inbound.makeAsyncIterator()
        let webSocketInbound = WebSocketInboundStream(
            iterator: inboundIterator,
            handler: self
        )
        try await withGracefulShutdownHandler {
            let closeCode: WebSocketErrorCode
            do {
                // handle websocket data and text
                try await handler(webSocketInbound, webSocketOutbound, context)
                closeCode = .normalClosure
            } catch InternalError.close(let code) {
                closeCode = code
            } catch {
                closeCode = .unexpectedServerError
            }
            try await self.close(code: closeCode)
            if case .closing = self.closeState {
                // Close handshake. Wait for responding close or until inbound ends
                while let frame = try await inboundIterator.next() {
                    if case .connectionClose = frame.opcode {
                        try await self.receivedClose(frame)
                        break
                    }
                }
            }
        } onGracefulShutdown: {
            Task {
                try? await self.close(code: .normalClosure)
            }
        }
        return switch self.closeState {
        case .closed(let code): code
        default: nil
        }
    }

    /// Send WebSocket frame
    func write(frame: WebSocketFrame) async throws {
        var frame = frame
        do {
            for ext in self.configuration.extensions {
                frame = try await ext.processFrameToSend(frame, context: self.context)
            }
        } catch {
            self.context.logger.debug("Closing as we failed to generate valid frame data")
            throw WebSocketHandler.InternalError.close(.unexpectedServerError)
        }
        // Set mask key if client
        if self.type == .client {
            frame.maskKey = self.makeMaskKey()
        }
        try await self.outbound.write(frame)

        self.context.logger.trace("Sent \(frame.traceDescription)")
    }

    func finish() {
        self.outbound.finish()
    }

    /// Respond to ping
    func onPing(
        _ frame: WebSocketFrame
    ) async throws {
        if frame.fin {
            try await self.pong(data: frame.unmaskedData)
        } else {
            try await self.close(code: .protocolError)
        }
    }

    /// Respond to pong
    func onPong(
        _ frame: WebSocketFrame
    ) throws {
        let frameData = frame.unmaskedData
        // ignore pong frames with frame data not the same as the last ping
        guard frameData == self.pingData else { return }
        // clear ping data
        self.pingData.clear()
    }

    /// Send ping
    func ping() async throws {
        guard case .open = self.closeState else { return }
        if self.pingData.readableBytes == 0 {
            // creating random payload
            let random = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
            self.pingData.writeBytes(random)
        }
        self.pingTime = .now
        try await self.write(frame: .init(fin: true, opcode: .ping, data: self.pingData))
    }

    /// Send pong
    func pong(data: ByteBuffer?) async throws {
        guard case .open = self.closeState else { return }
        try await self.write(frame: .init(fin: true, opcode: .pong, data: data ?? .init()))
    }

    /// Return time ping occurred if it is still waiting for a pong
    func getTimeSinceLastWaitingPing() -> Duration? {
        guard self.pingData.readableBytes > 0 else { return nil }
        return .now - self.pingTime
    }

    /// Send close
    func close(
        code: WebSocketErrorCode = .normalClosure
    ) async throws {
        switch self.closeState {
        case .open:
            var buffer = self.context.allocator.buffer(capacity: 2)
            buffer.write(webSocketErrorCode: code)

            try await self.write(frame: .init(fin: true, opcode: .connectionClose, data: buffer))
            // Only server should initiate a connection close. Clients should wait for the
            // server to close the connection when it receives the WebSocket close packet
            // See https://www.rfc-editor.org/rfc/rfc6455#section-7.1.1
            if self.type == .server {
                self.outbound.finish()
            }
            self.closeState = .closing
        default:
            break
        }
    }

    func receivedClose(_ frame: WebSocketFrame) async throws {
        // we received a connection close.
        // send a close back if it hasn't already been send and exit
        var data = frame.unmaskedData
        let dataSize = data.readableBytes
        let closeCode = data.readWebSocketErrorCode()

        switch self.closeState {
        case .open:
            let code: WebSocketErrorCode = if dataSize == 0 || closeCode != nil {
                if case .unknown = closeCode {
                    .protocolError
                } else {
                    .normalClosure
                }
            } else {
                .protocolError
            }
            var buffer = self.context.allocator.buffer(capacity: 2)
            buffer.write(webSocketErrorCode: code)

            try await self.write(frame: .init(fin: true, opcode: .connectionClose, data: buffer))
            // Only server should initiate a connection close. Clients should wait for the
            // server to close the connection when it receives the WebSocket close packet
            // See https://www.rfc-editor.org/rfc/rfc6455#section-7.1.1
            if self.type == .server {
                self.outbound.finish()
            }
            self.closeState = .closing

        case .closing:
            self.closeState = .closed(closeCode)

        default:
            break
        }
    }

    /// Make mask key to be used in WebSocket frame
    private func makeMaskKey() -> WebSocketMaskingKey? {
        guard self.type == .client else { return nil }
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: .min ... .max) }
        return WebSocketMaskingKey(bytes)
    }
}

extension WebSocketErrorCode {
    init(_ error: any Error) {
        switch error {
        case NIOWebSocketError.invalidFrameLength:
            self = .messageTooLarge
        case NIOWebSocketError.fragmentedControlFrame,
             NIOWebSocketError.multiByteControlFrameLength:
            self = .protocolError
        case WebSocketHandler.InternalError.close(let error):
            self = error
        default:
            self = .unexpectedServerError
        }
    }
}
