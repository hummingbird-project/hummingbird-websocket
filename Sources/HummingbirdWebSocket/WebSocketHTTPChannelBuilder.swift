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

import HummingbirdCore
import NIOCore
import NIOHTTP1

extension HBHTTPChannelBuilder {
    public static func httpAndWebSocket(
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        maxFrameSize: Int = 1 << 14,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) async throws -> ShouldUpgradeResult<WebSocketHandler>
    ) -> HBHTTPChannelBuilder<HTTP1AndWebSocketChannel> {
        return .init { responder in
            return HTTP1AndWebSocketChannel(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder,
                maxFrameSize: maxFrameSize,
                shouldUpgrade: { channel, head in
                    let promise = channel.eventLoop.makePromise(of: ShouldUpgradeResult<WebSocketHandler>.self)
                    promise.completeWithTask {
                        try await shouldUpgrade(channel, head)
                    }
                    return promise.futureResult
                }
            )
        }
    }

    public static func httpAndWebSocket(
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        maxFrameSize: Int = 1 << 14,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) throws -> ShouldUpgradeResult<WebSocketHandler>
    ) -> HBHTTPChannelBuilder<HTTP1AndWebSocketChannel> {
        return .init { responder in
            return HTTP1AndWebSocketChannel(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder,
                maxFrameSize: maxFrameSize,
                shouldUpgrade: { channel, head in 
                    channel.eventLoop.makeCompletedFuture { try shouldUpgrade(channel, head) } 
                }
            )
        }
    }
}
