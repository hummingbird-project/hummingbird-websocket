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

actor HBWebSocketHandler: Sendable {
    enum SocketType: Sendable {
        case client
        case server
    }

    static let pingDataSize = 16

    let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    let type: SocketType
    var closed = false
    var pingData: ByteBuffer

    init(asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, type: HBWebSocketHandler.SocketType) {
        self.asyncChannel = asyncChannel
        self.type = type
        self.pingData = ByteBufferAllocator().buffer(capacity: Self.pingDataSize)
    }

    /// Handle WebSocket AsynChannel
    func handle<Handler: HBWebSocketDataHandler>(
        handler: Handler,
        context: Handler.Context
    ) async {
        try? await self.asyncChannel.executeThenClose { inbound, outbound in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    let webSocketHandlerInbound = WebSocketHandlerInbound()
                    defer {
                        asyncChannel.channel.close(promise: nil)
                        webSocketHandlerInbound.finish()
                    }
                    let webSocketHandlerOutbound = WebSocketHandlerOutboundWriter(webSocket: self, outbound: outbound)
                    group.addTask {
                        var frameSequence: WebSocketFrameSequence?
                        for try await frame in inbound {
                            switch frame.opcode {
                            case .connectionClose:
                                return
                            case .ping:
                                try await self.onPing(frame, outbound: outbound, context: context)
                            case .pong:
                                try await self.onPong(frame, outbound: outbound, context: context)
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
                                    try await self.close(code: .protocolError, outbound: outbound, context: context)
                                }
                            default:
                                break
                            }
                            if let frameSeq = frameSequence, frame.fin {
                                await webSocketHandlerInbound.send(frameSeq.data)
                                frameSequence = nil
                            }
                        }
                    }
                    group.addTask {
                        try await handler.handle(webSocketHandlerInbound, webSocketHandlerOutbound, context: context)
                        try await self.close(code: .normalClosure, outbound: outbound, context: context)
                    }
                    try await group.next()
                }
            } catch let error as NIOWebSocketError {
                let errorCode = WebSocketErrorCode(error)
                try await self.close(code: errorCode, outbound: outbound, context: context)
            } catch {
                let errorCode = WebSocketErrorCode.unexpectedServerError
                try await self.close(code: errorCode, outbound: outbound, context: context)
            }
        }
    }

    /// Respond to ping
    func onPing(
        _ frame: WebSocketFrame,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        context: some HBWebSocketContextProtocol
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
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        context: some HBWebSocketContextProtocol
    ) async throws {
        let frameData = frame.unmaskedData
        guard self.pingData.readableBytes == 0 || frameData == self.pingData else {
            try await self.close(code: .goingAway, outbound: outbound, context: context)
            return
        }
        self.pingData.clear()
    }

    /// Send ping
    func ping(outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
        guard !self.closed else { return }
        if self.pingData.readableBytes == 0 {
            // creating random payload
            let random = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
            self.pingData.writeBytes(random)
        }
        try await self.send(frame: .init(fin: true, opcode: .ping, data: self.pingData), outbound: outbound)
    }

    /// Send pong
    func pong(data: ByteBuffer?, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
        guard !self.closed else { return }
        try await self.send(frame: .init(fin: true, opcode: .pong, data: data ?? .init()), outbound: outbound)
    }

    /// Send close
    func close(
        code: WebSocketErrorCode = .normalClosure,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        context: some HBWebSocketContextProtocol
    ) async throws {
        guard !self.closed else { return }
        self.closed = true

        var buffer = context.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        try await self.send(frame: .init(fin: true, opcode: .connectionClose, data: buffer), outbound: outbound)
    }

    /// Send WebSocket frame
    func send(
        frame: WebSocketFrame,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        var frame = frame
        frame.maskKey = self.makeMaskKey()
        try await outbound.write(frame)
    }

    /// Make mask key to be used in WebSocket frame
    private func makeMaskKey() -> WebSocketMaskingKey? {
        guard self.type == .client else { return nil }
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: .min ... .max) }
        return WebSocketMaskingKey(bytes)
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
