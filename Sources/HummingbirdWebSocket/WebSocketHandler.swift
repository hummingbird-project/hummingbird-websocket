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

import Hummingbird
import Logging
import NIOCore
import NIOWebSocket
import ServiceLifecycle

/// WebSocket type
public enum WebSocketType: Sendable {
    case client
    case server
}

/// Handler processing raw WebSocket packets.
///
/// Manages ping, pong and close messages. Collates data and text messages into final frame
/// and passes them onto the ``WebSocketDataHandler`` data handler setup by the user.
actor WebSocketHandler {
    enum InternalError: Error {
        case close(WebSocketErrorCode)
    }

    static let pingDataSize = 16
    var outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    let type: WebSocketType
    let extensions: [any WebSocketExtension]
    let context: WebSocketContext
    var pingData: ByteBuffer
    var closed = false

    private init(
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        type: WebSocketType,
        extensions: [any WebSocketExtension],
        context: some WebSocketContextProtocol
    ) {
        self.outbound = outbound
        self.type = type
        self.extensions = extensions
        self.context = .init(allocator: context.allocator, logger: context.logger)
        self.pingData = ByteBufferAllocator().buffer(capacity: Self.pingDataSize)
        self.closed = false
    }

    static func handle<Context: WebSocketContextProtocol>(
        type: WebSocketType,
        extensions: [any WebSocketExtension],
        asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        context: Context,
        handler: @escaping WebSocketDataHandler<Context>
    ) async {
        try? await asyncChannel.executeThenClose { inbound, outbound in
            await withTaskCancellationHandler {
                await withThrowingTaskGroup(of: Void.self) { _ in
                    let webSocketHandler = Self(outbound: outbound, type: type, extensions: extensions, context: context)
                    await webSocketHandler.handle(inbound: inbound, outbound: outbound, handler: handler, context: context)
                }
            } onCancel: {
                Task {
                    try await asyncChannel.channel.close(mode: .input)
                }
            }
        }
        context.logger.debug("Closed WebSocket")
    }

    func handle<Context: WebSocketContextProtocol>(
        inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        handler: @escaping WebSocketDataHandler<Context>,
        context: Context
    ) async {
        let webSocketOutbound = WebSocketOutboundWriter(handler: self)
        var inboundIterator = inbound.makeAsyncIterator()
        let webSocketInbound = WebSocketInboundStream(
            inboundIterator: inboundIterator,
            handler: self
        )
        try? await withGracefulShutdownHandler {
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
            // Close handshake. Wait for responding close or until inbound ends
            while let packet = try await inboundIterator.next() {
                if case .connectionClose = packet.opcode {
                    // we received a connection close.
                    // send a close back if it hasn't already been send and exit
                    _ = try await self.close(code: .normalClosure)
                    break
                }
            }
        } onGracefulShutdown: {
            Task {
                try? await self.close(code: .normalClosure)
            }
        }
    }

    /// Send WebSocket frame
    func write(frame: WebSocketFrame) async throws {
        var frame = frame
        do {
            for ext in self.extensions {
                frame = try await ext.processFrameToSend(frame, context: self.context)
            }
        } catch {
            self.context.logger.debug("Closing as we failed to generate valid frame data")
            throw WebSocketHandler.InternalError.close(.unexpectedServerError)
        }
        frame.maskKey = self.makeMaskKey()
        try await self.outbound.write(frame)

        self.context.logger.trace("Sent \(frame.opcode)")
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
    ) async throws {
        let frameData = frame.unmaskedData
        guard self.pingData.readableBytes == 0 || frameData == self.pingData else {
            try await self.close(code: .goingAway)
            return
        }
        self.pingData.clear()
    }

    /// Send ping
    func ping() async throws {
        guard !self.closed else { return }
        if self.pingData.readableBytes == 0 {
            // creating random payload
            let random = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
            self.pingData.writeBytes(random)
        }
        try await self.outbound.write(.init(fin: true, opcode: .ping, data: self.pingData))
    }

    /// Send pong
    func pong(data: ByteBuffer?) async throws {
        guard !self.closed else { return }
        try await self.outbound.write(.init(fin: true, opcode: .pong, data: data ?? .init()))
    }

    /// Send close
    func close(
        code: WebSocketErrorCode = .normalClosure
    ) async throws {
        guard !self.closed else { return }
        self.closed = true

        var buffer = self.context.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        try await self.outbound.write(.init(fin: true, opcode: .connectionClose, data: buffer))
        self.outbound.finish()
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
        default:
            self = .unexpectedServerError
        }
    }
}
