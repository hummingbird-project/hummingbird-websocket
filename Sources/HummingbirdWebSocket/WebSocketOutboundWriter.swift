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
public struct WebSocketOutboundWriter: Sendable {
    /// WebSocket frame that can be written
    public enum OutboundFrame: Sendable {
        /// Text frame
        case text(String)
        /// Binary data frame
        case binary(ByteBuffer)
        /// Unsolicited pong frame
        case pong
        /// A custom frame not supported by the above
        case custom(WebSocketFrame)
    }

    let type: WebSocketType
    let allocator: ByteBufferAllocator
    let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>

    /// Write WebSocket frame
    public func write(_ frame: OutboundFrame) async throws {
        try Task.checkCancellation()
        switch frame {
        case .binary(let buffer):
            // send binary data
            try await self.write(frame: .init(fin: true, opcode: .binary, data: buffer))
        case .text(let string):
            // send text based data
            let buffer = self.allocator.buffer(string: string)
            try await self.write(frame: .init(fin: true, opcode: .text, data: buffer))
        case .pong:
            // send unexplained pong as a heartbeat
            try await self.write(frame: .init(fin: true, opcode: .pong, data: .init()))
        case .custom(let frame):
            // send custom WebSocketFrame
            try await self.write(frame: frame)
        }
    }

    /// Send WebSocket frame
    func write(
        frame: WebSocketFrame
    ) async throws {
        var frame = frame
        frame.maskKey = self.makeMaskKey()
        try await self.outbound.write(frame)
    }

    func finish() {
        self.outbound.finish()
    }

    /// Make mask key to be used in WebSocket frame
    private func makeMaskKey() -> WebSocketMaskingKey? {
        guard self.type == .client else { return nil }
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: .min ... .max) }
        return WebSocketMaskingKey(bytes)
    }
}
