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

/// Handler processing raw WebSocket packets.
///
/// Manages ping, pong and close messages. Collates data and text messages into final frame
/// and passes them onto the ``WebSocketDataHandler`` data handler setup by the user.
actor WebSocketHandler: Sendable {
    static let pingDataSize = 16

    let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    let type: WebSocket.SocketType
    var closed: Bool
    var pingData: ByteBuffer

    init(asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, type: WebSocket.SocketType) {
        self.asyncChannel = asyncChannel
        self.type = type
        self.pingData = ByteBufferAllocator().buffer(capacity: Self.pingDataSize)
        self.closed = false
    }

    /// Handle WebSocket AsynChannel
    func handle<Context: WebSocketContextProtocol>(handler: @escaping WebSocketDataHandler<Context>, context: Context) async {
        let asyncChannel = self.asyncChannel
        try? await asyncChannel.executeThenClose { inbound, outbound in
            let webSocket = WebSocket(type: self.type, outbound: outbound, allocator: asyncChannel.channel.allocator)
            try await withTaskCancellationHandler {
                try await withGracefulShutdownHandler {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            defer {
                                webSocket.inbound.finish()
                            }
                            // parse messages coming from inbound
                            var frameSequence: WebSocketFrameSequence?
                            for try await frame in inbound {
                                do {
                                    context.logger.trace("Received \(frame.opcode)")
                                    switch frame.opcode {
                                    case .connectionClose:
                                        // we received a connection close. Finish the inbound data stream,
                                        // send a close back if it hasn't already been send and exit
                                        webSocket.inbound.finish()
                                        _ = try await self.close(code: .normalClosure, outbound: webSocket.outbound, context: context)
                                        return
                                    case .ping:
                                        try await self.onPing(frame, outbound: webSocket.outbound, context: context)
                                    case .pong:
                                        try await self.onPong(frame, outbound: webSocket.outbound, context: context)
                                    case .text, .binary:
                                        if var frameSeq = frameSequence {
                                            frameSeq.append(frame)
                                            frameSequence = frameSeq
                                        } else {
                                            frameSequence = WebSocketFrameSequence(frame: frame)
                                        }
                                    case .continuation:
                                        if var frameSeq = frameSequence {
                                            frameSeq.append(frame)
                                            frameSequence = frameSeq
                                        } else {
                                            try await self.close(code: .protocolError, outbound: webSocket.outbound, context: context)
                                        }
                                    default:
                                        break
                                    }
                                    if let frameSeq = frameSequence, frame.fin {
                                        await webSocket.inbound.send(frameSeq.data)
                                        frameSequence = nil
                                    }
                                } catch let error as NIOWebSocketError {
                                    let errorCode = WebSocketErrorCode(error)
                                    try await self.close(code: errorCode, outbound: webSocket.outbound, context: context)
                                } catch {
                                    let errorCode = WebSocketErrorCode.unexpectedServerError
                                    try await self.close(code: errorCode, outbound: webSocket.outbound, context: context)
                                }
                            }
                        }
                        group.addTask {
                            do {
                                // handle websocket data and text
                                try await handler(webSocket, context)
                                try await self.close(code: .normalClosure, outbound: webSocket.outbound, context: context)
                            } catch {
                                if self.type == .server {
                                    let errorCode = WebSocketErrorCode.unexpectedServerError
                                    try await self.close(code: errorCode, outbound: webSocket.outbound, context: context)
                                } else {
                                    try await asyncChannel.channel.close(mode: .input)
                                }
                            }
                        }
                        try await group.next()
                        webSocket.inbound.finish()
                    }
                } onGracefulShutdown: {
                    Task {
                        try? await self.close(code: .normalClosure, outbound: webSocket.outbound, context: context)
                    }
                }
            } onCancel: {
                Task {
                    webSocket.inbound.finish()
                    try await asyncChannel.channel.close(mode: .input)
                }
            }
        }
        context.logger.debug("Closed WebSocket")
    }

    /// Respond to ping
    func onPing(
        _ frame: WebSocketFrame,
        outbound: WebSocketOutboundWriter,
        context: some WebSocketContextProtocol
    ) async throws {
        if frame.fin {
            try await self.pong(data: frame.unmaskedData, outbound: outbound)
        } else {
            try await self.close(code: .protocolError, outbound: outbound, context: context)
        }
    }

    /// Respond to pong
    func onPong(
        _ frame: WebSocketFrame,
        outbound: WebSocketOutboundWriter,
        context: some WebSocketContextProtocol
    ) async throws {
        guard !self.closed else { return }
        let frameData = frame.unmaskedData
        guard self.pingData.readableBytes == 0 || frameData == self.pingData else {
            try await self.close(code: .goingAway, outbound: outbound, context: context)
            return
        }
        self.pingData.clear()
    }

    /// Send ping
    func ping(outbound: WebSocketOutboundWriter) async throws {
        guard !self.closed else { return }
        if self.pingData.readableBytes == 0 {
            // creating random payload
            let random = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
            self.pingData.writeBytes(random)
        }
        try await outbound.write(frame: .init(fin: true, opcode: .ping, data: self.pingData))
    }

    /// Send pong
    func pong(data: ByteBuffer?, outbound: WebSocketOutboundWriter) async throws {
        guard !self.closed else { return }
        try await outbound.write(frame: .init(fin: true, opcode: .pong, data: data ?? .init()))
    }

    /// Send close
    func close(
        code: WebSocketErrorCode = .normalClosure,
        outbound: WebSocketOutboundWriter,
        context: some WebSocketContextProtocol
    ) async throws {
        guard !self.closed else { return }
        self.closed = true

        var buffer = context.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        try await outbound.write(frame: .init(fin: true, opcode: .connectionClose, data: buffer))
        outbound.finish()
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
