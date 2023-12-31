//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023 the Hummingbird authors
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

actor HBWebSocket: Sendable {
    enum SocketType: Sendable {
        case client
        case server
    }

    let type: SocketType
    let logger: Logger
    let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    var closed = false

    init(
        asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, 
        type: HBWebSocket.SocketType, 
        logger: Logger
    ) {
        self.asyncChannel = asyncChannel
        self.logger = logger
        self.type = type
    }

    func handle(_ handler: @escaping WebSocketHandler) async {
        try? await self.asyncChannel.executeThenClose { inbound, outbound in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    let webSocketHandlerInbound = WebSocketHandlerInbound()
                    defer {
                        self.asyncChannel.channel.close(promise: nil)
                        webSocketHandlerInbound.finish()
                    }
                    let webSocketHandlerOutbound = WebSocketHandlerOutbound(webSocket: self, outbound: outbound)
                    group.addTask {
                        var frameSequence: WebSocketFrameSequence?
                        for try await frame in inbound {
                            switch frame.opcode {
                            case .connectionClose:
                                return
                            case .ping:
                                try await self.onPing(frame, outbound: outbound)
                            case .pong:
                                // need to verify data
                                break
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
                                    try await self.close(code: .protocolError, outbound: outbound)
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
                        try await handler(webSocketHandlerInbound, webSocketHandlerOutbound)
                        try await self.close(code: .normalClosure, outbound: outbound)
                    }
                    try await group.next()
                }
            } catch let error as NIOWebSocketError {
                let errorCode = WebSocketErrorCode(error)
                try await self.close(code: errorCode, outbound: outbound)
            } catch {
                let errorCode = WebSocketErrorCode.unexpectedServerError
                try await self.close(code: errorCode, outbound: outbound)
            }
        }
    }

    func onPing(_ frame: WebSocketFrame, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
        if frame.fin {
            try await self.send(buffer: frame.unmaskedData, opcode: .pong, fin: true, outbound: outbound)
        } else {
            try await self.close(code: .protocolError, outbound: outbound)
        }
    }

    func close(code: WebSocketErrorCode = .normalClosure, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
        guard !self.closed else { return }
        self.closed = true

        var buffer = self.asyncChannel.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        try await self.send(buffer: buffer, opcode: .connectionClose, fin: true, outbound: outbound)
    }

    func send(
        buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        var frame = WebSocketFrame(fin: fin, opcode: opcode, data: buffer)
        frame.maskKey = makeMaskKey()
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
