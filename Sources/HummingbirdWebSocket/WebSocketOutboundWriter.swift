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

import NIOCore
import NIOWebSocket

/// Outbound websocket writer
public struct HBWebSocketHandlerOutboundWriter {
    /// WebSocket frame that can be written
    public enum OutboundFrame: Sendable {
        /// Text frame
        case text(String)
        /// Binary data frame
        case binary(ByteBuffer)
        /// Unsolicited pong frame
        case pong
        /// A ping frame. The returning pong will be dealt with by the underlying code
        case ping
        /// A custom frame not supported by the above
        case custom(WebSocketFrame)
    }

    let webSocket: HBWebSocketHandler
    let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>

    /// Write WebSocket frame
    public func write(_ frame: OutboundFrame) async throws {
        try Task.checkCancellation()
        switch frame {
        case .binary(let buffer):
            // send binary data
            try await self.webSocket.send(frame: .init(fin: true, opcode: .binary, data: buffer), outbound: self.outbound)
        case .text(let string):
            // send text based data
            let buffer = self.webSocket.asyncChannel.channel.allocator.buffer(string: string)
            try await self.webSocket.send(frame: .init(fin: true, opcode: .text, data: buffer), outbound: self.outbound)
        case .ping:
            // send ping
            try await self.webSocket.ping(outbound: self.outbound)
        case .pong:
            // send unexplained pong as a heartbeat
            try await self.webSocket.pong(data: nil, outbound: self.outbound)
        case .custom(let frame):
            // send custom WebSocketFrame
            try await self.webSocket.send(frame: frame, outbound: self.outbound)
        }
    }
}

