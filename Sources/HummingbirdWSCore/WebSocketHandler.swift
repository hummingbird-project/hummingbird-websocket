//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
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

/// WebSocket channel handler. Passes web socket frames onto `HBWebSocket` object.
///
/// The handler combines fragmented frames together before passing them onto
/// the `HBWebSocket`.
public final class WebSocketHandler: ChannelInboundHandler {
    public typealias InboundIn = WebSocketFrame

    var webSocketFrameSequence: WebSocketFrameSequence?
    var webSocket: HBWebSocket

    public init(webSocket: HBWebSocket) {
        self.webSocket = webSocket
    }

    /// Read WebSocket frame
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .pong:
            self.webSocket.receivedPong(frame: frame)
        case .ping:
            self.webSocket.receivedPing(frame: frame)
        case .text:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                var frameSeq = WebSocketFrameSequence(type: .text)
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            }
        case .binary:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                var frameSeq = WebSocketFrameSequence(type: .binary)
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            }
        case .continuation:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                self.webSocket.close(code: .protocolError, promise: nil)
            }
        case .connectionClose:
            self.webSocket.receivedClose(frame: frame)

        default:
            break
        }

        if let frameSeq = self.webSocketFrameSequence, frame.fin {
            self.webSocket.read(frameSeq.combinedResult)
            self.webSocketFrameSequence = nil
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // client has closed the input channel now we can close the channel fully
            context.close(promise: nil)

        case is ChannelShouldQuiesceEvent:
            // we received a quiesce event so send close message.
            self.webSocket.close(code: .goingAway, promise: nil)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.webSocket.close(code: .goingAway, promise: nil)
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.webSocket.errorCaught(error)
        context.fireErrorCaught(error)
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
