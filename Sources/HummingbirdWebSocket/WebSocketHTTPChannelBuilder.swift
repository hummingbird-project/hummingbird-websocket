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
        maxFrameSize: Int = 1 << 14
    ) -> HBHTTPChannelBuilder<HTTP1AndWebSocketChannel> {
        return .init { responder in
            let handler: WebSocketHandler = { inbound, outbound in
                for try await data in inbound {
                    if case .text("disconnect") = data {
                        break
                    }
                    try await outbound.write(data)
                }
            }
            return HTTP1AndWebSocketChannel(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder,
                maxFrameSize: maxFrameSize,
                shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(.upgraded(.init(), handler)) }
            )
        }
    }
}
