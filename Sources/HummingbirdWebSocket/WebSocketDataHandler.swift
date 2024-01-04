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

import AsyncAlgorithms
import NIOCore
import NIOWebSocket

/// Protocol for web socket data handling
///
/// The user needs to return a type conforming to this protocol in the `shouldUpgrade`
/// closure in HTTP1AndWebSocketChannel.init
public protocol HBWebSocketDataHandler: Sendable {
    /// Context type supplied to the handle function
    associatedtype Context: HBWebSocketContextProtocol = HBWebSocketContext
    /// If a `HBWebSocketDataHandler` requires a context with custom data it should
    /// setup this variable on initialization
    var alreadySetupContext: Context? { get }
    ///  Handler WebSocket data packets
    /// - Parameters:
    ///   - inbound: An AsyncSequence of text or binary WebSocket frames.
    ///   - outbound: An outbound Writer to write websocket frames to
    ///   - context: Associated context to this websocket channel
    func handle(_ inbound: WebSocketHandlerInbound, _ outbound: WebSocketHandlerOutboundWriter, context: Context) async throws
}

extension HBWebSocketDataHandler {
    /// Default implementaion of ``alreadySetupContext`` returns nil, so the Context will be
    /// created by the ``WebSocketChannelHandler``
    public var alreadySetupContext: Context? { nil }
}

/// HBWebSocketDataHandler that is is initialized via a callback
public struct HBWebSocketDataCallbackHandler: HBWebSocketDataHandler {
    public typealias Callback = @Sendable (WebSocketHandlerInbound, WebSocketHandlerOutboundWriter, HBWebSocketContext) async throws -> Void

    let callback: Callback

    public init(_ callback: @escaping Callback) {
        self.callback = callback
    }

    ///  Handler WebSocket data packets by passing directly to the callback
    public func handle(_ inbound: WebSocketHandlerInbound, _ outbound: WebSocketHandlerOutboundWriter, context: HBWebSocketContext) async throws {
        try await self.callback(inbound, outbound, context)
    }
}

/// Inbound websocket data AsyncSequence
public typealias WebSocketHandlerInbound = AsyncChannel<WebSocketDataFrame>
/// Outbound websocket writer
public struct WebSocketHandlerOutboundWriter {
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

/// Enumeration holding WebSocket data
public enum WebSocketDataFrame: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case text(String)
    case binary(ByteBuffer)

    init?(frame: WebSocketFrame) {
        switch frame.opcode {
        case .text:
            self = .text(String(buffer: frame.unmaskedData))
        case .binary:
            self = .binary(frame.unmaskedData)
        default:
            return nil
        }
    }

    public var webSocketFrame: WebSocketFrame {
        switch self {
        case .text(let string):
            return .init(fin: true, opcode: .text, data: ByteBuffer(string: string))
        case .binary(let buffer):
            return .init(fin: true, opcode: .binary, data: buffer)
        }
    }

    public var description: String {
        switch self {
        case .text(let string):
            return "string(\"\(string)\")"
        case .binary(let buffer):
            return "binary(\(buffer.description))"
        }
    }

    public var debugDescription: String {
        switch self {
        case .text(let string):
            return "string(\"\(string)\")"
        case .binary(let buffer):
            return "binary(\(buffer.debugDescription))"
        }
    }
}
