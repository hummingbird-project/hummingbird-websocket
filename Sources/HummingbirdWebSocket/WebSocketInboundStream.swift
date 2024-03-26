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
import NIOConcurrencyHelpers
import NIOCore
import NIOWebSocket

private let webSocketPingDataSize = 16

/// Inbound websocket data AsyncSequence
// public typealias WebSocketInboundStream = AsyncChannel<WebSocketDataFrame>

public final class WebSocketInboundStream: AsyncSequence, Sendable {
    typealias InboundIterator = NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator
    let inboundIterator: UnsafeTransfer<InboundIterator>
    let handler: WebSocketHandler

    init(
        inboundIterator: InboundIterator,
        handler: WebSocketHandler
    ) {
        self.inboundIterator = .init(inboundIterator)
        self.handler = handler
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let handler: WebSocketHandler
        var iterator: InboundIterator

        init(sequence: WebSocketInboundStream) {
            self.handler = sequence.handler
            self.iterator = sequence.inboundIterator.wrappedValue
        }

        public mutating func next() async throws -> WebSocketDataFrame? {
            // parse messages coming from inbound
            var frameSequence: WebSocketFrameSequence?
            while let frame = try await self.iterator.next() {
                do {
                    self.handler.context.logger.trace("Received \(frame.opcode)")
                    switch frame.opcode {
                    case .connectionClose:
                        // we received a connection close.
                        // send a close back if it hasn't already been send and exit
                        _ = try await self.handler.close(code: .normalClosure)
                        return nil
                    case .ping:
                        try await self.handler.onPing(frame)
                    case .pong:
                        try await self.handler.onPong(frame)
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
                            try await self.handler.close(code: .protocolError)
                        }
                    default:
                        break
                    }
                    if let frameSeq = frameSequence, frame.fin {
                        var collatedFrame = frameSeq.collapsed
                        for ext in self.handler.extensions.reversed() {
                            collatedFrame = try await ext.processReceivedFrame(collatedFrame, context: self.handler.context)
                        }
                        if let finalFrame = WebSocketDataFrame(frame: collatedFrame) {
                            frameSequence = nil
                            return finalFrame
                        }
                    }
                } catch {
                    // catch errors while processing websocket frames so responding close message
                    // can be dealt with
                    let errorCode = WebSocketErrorCode(error)
                    try await self.handler.close(code: errorCode)
                }
            }

            return nil
        }
    }

    public typealias Element = WebSocketDataFrame

    public func makeAsyncIterator() -> AsyncIterator {
        .init(sequence: self)
    }
}
