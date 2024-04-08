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

    let handler: WebSocketHandler

    /// Write WebSocket frame
    public func write(_ frame: OutboundFrame) async throws {
        try Task.checkCancellation()
        switch frame {
        case .binary(let buffer):
            // send binary data
            try await self.handler.write(frame: .init(fin: true, opcode: .binary, data: buffer))
        case .text(let string):
            // send text based data
            let buffer = self.handler.context.allocator.buffer(string: string)
            try await self.handler.write(frame: .init(fin: true, opcode: .text, data: buffer))
        case .pong:
            // send unexplained pong as a heartbeat
            try await self.handler.write(frame: .init(fin: true, opcode: .pong, data: .init()))
        case .custom(let frame):
            // send custom WebSocketFrame
            try await self.handler.write(frame: frame)
        }
    }

    struct MessageWriter {
        let handler: WebSocketHandler
        var prevFrame: WebSocketFrame?
        mutating func write(_ data: ByteBuffer, opcode: WebSocketOpcode) async throws {
            if let prevFrame {
                try await self.handler.write(frame: prevFrame)
                self.prevFrame = .init(fin: false, opcode: .continuation, data: data)
            } else {
                self.prevFrame = .init(fin: false, opcode: opcode, data: data)
            }
        }

        func finish() async throws {
            if var prevFrame {
                prevFrame.fin = true
                try await self.handler.write(frame: prevFrame)
            }
        }
    }

    /// Write a single WebSocket text message as a series of fragmented frames
    /// - Parameter write: Function writing frames
    public func withTextMessageWriter<Value>(_ write: ((String) async throws -> Void) async throws -> Value) async throws -> Value {
        var writer = MessageWriter(handler: self.handler)
        let value: Value
        do {
            value = try await write { text in
                let data = writer.handler.context.allocator.buffer(string: text)
                try await writer.write(data, opcode: .text)
            }
        } catch {
            try await writer.finish()
            throw error
        }
        try await writer.finish()
        return value
    }

    /// Write a single WebSocket binary message as a series of fragmented frames
    /// - Parameter write: Function writing frames
    public func withBinaryMessageWriter<Value>(_ write: ((ByteBuffer) async throws -> Void) async throws -> Value) async throws -> Value {
        var writer = MessageWriter(handler: self.handler)
        let value: Value
        do {
            value = try await write { data in
                try await writer.write(data, opcode: .binary)
            }
        } catch {
            try await writer.finish()
            throw error
        }
        try await writer.finish()
        return value
    }
}
