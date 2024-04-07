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

/// Inbound WebSocket frame AsyncSequence
///
/// This AsyncSequence only returns binary, text and continuation frames. All other frames
/// are dealt with internally
public final class WebSocketInboundStream: AsyncSequence, Sendable {
    public typealias Element = WebSocketFrame

    typealias UnderlyingIterator = NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator
    /// Underlying NIOAsyncChannelInboundStream
    let underlyingIterator: UnsafeTransfer<UnderlyingIterator>
    /// Handler for websockets
    let handler: WebSocketHandler
    internal let alreadyIterated: NIOLockedValueBox<Bool>

    init(
        iterator: UnderlyingIterator,
        handler: WebSocketHandler
    ) {
        self.underlyingIterator = .init(iterator)
        self.handler = handler
        self.alreadyIterated = .init(false)
    }

    /// Inbound websocket data AsyncSequence iterator
    public struct AsyncIterator: AsyncIteratorProtocol {
        let handler: WebSocketHandler
        var iterator: UnderlyingIterator
        var closed: Bool

        init(sequence: WebSocketInboundStream, closed: Bool) {
            self.handler = sequence.handler
            self.iterator = sequence.underlyingIterator.wrappedValue
            self.closed = closed
        }

        /// Return next WebSocket frame, while dealing with any other frames
        public mutating func next() async throws -> WebSocketFrame? {
            guard !self.closed else { return nil }
            // parse messages coming from inbound
            while let frame = try await self.iterator.next() {
                do {
                    self.handler.context.logger.trace("Received \(frame.opcode)")
                    switch frame.opcode {
                    case .connectionClose:
                        // we received a connection close.
                        // send a close back if it hasn't already been send and exit
                        _ = try await self.handler.close(code: .normalClosure)
                        self.closed = true
                        return nil
                    case .ping:
                        try await self.handler.onPing(frame)
                    case .pong:
                        try await self.handler.onPong(frame)
                    case .text, .binary, .continuation:
                        // apply extensions
                        var collatedFrame = frame
                        for ext in self.handler.configuration.extensions.reversed() {
                            collatedFrame = try await ext.processReceivedFrame(collatedFrame, context: self.handler.context)
                        }
                        return collatedFrame
                    default:
                        break
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

    /// Creates the Asynchronous Iterator
    public func makeAsyncIterator() -> AsyncIterator {
        // verify if an iterator has already been created. If it has then create an
        // iterator that returns nothing. This could be a precondition failure (currently
        // an assert) as you should not be allowed to do this.
        let done = self.alreadyIterated.withLockedValue {
            assert($0 == false, "Can only create iterator from WebSocketInboundStream once")
            let done = $0
            $0 = true
            return done
        }
        return .init(sequence: self, closed: done)
    }
}

/// Inbound WebSocket messages AsyncSequence.
public struct WebSocketInboundMessageStream: AsyncSequence, Sendable {
    public typealias Element = WebSocketMessage

    let inboundStream: WebSocketInboundStream
    let maxMessageSize: Int

    public struct AsyncIterator: AsyncIteratorProtocol {
        var frameIterator: WebSocketInboundStream.AsyncIterator
        let maxMessageSize: Int

        public mutating func next() async throws -> Element? {
            // parse messages coming from inbound
            var frameSequence: WebSocketFrameSequence?
            while let frame = try await self.frameIterator.next() {
                do {
                    switch frame.opcode {
                    case .text, .binary:
                        guard frameSequence == nil else {
                            try await self.frameIterator.handler.close(code: .protocolError)
                            return nil
                        }
                        frameSequence = .init(frame: frame)
                    case .continuation:
                        if var frameSeq = frameSequence {
                            frameSeq.append(frame)
                            guard frameSeq.size <= self.maxMessageSize else {
                                try await self.frameIterator.handler.close(code: .messageTooLarge)
                                return nil
                            }
                            frameSequence = frameSeq
                        } else {
                            try await self.frameIterator.handler.close(code: .protocolError)
                            return nil
                        }
                    default:
                        break
                    }
                    if let frameSeq = frameSequence, frameSeq.finished {
                        let collatedFrame = frameSeq.collapsed
                        if let finalFrame = WebSocketMessage(frame: collatedFrame) {
                            frameSequence = nil
                            return finalFrame
                        }
                    }
                }
            }
            return nil
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        .init(frameIterator: self.inboundStream.makeAsyncIterator(), maxMessageSize: self.maxMessageSize)
    }
}

extension WebSocketInboundStream {
    /// Convert to AsyncSequence of WebSocket messages
    ///
    /// A WebSocket message is a text or binary frame combined with any subsequent continuation
    /// frames until a frame with a FIN flag is reached.
    ///
    /// - Parameter maxMessageSize: The maximum size of message we are allowed to create
    public func messages(maxMessageSize: Int) -> WebSocketInboundMessageStream {
        .init(inboundStream: self, maxMessageSize: maxMessageSize)
    }
}
