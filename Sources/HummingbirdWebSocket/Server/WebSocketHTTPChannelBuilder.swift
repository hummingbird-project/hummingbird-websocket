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

import HTTPTypes
import HummingbirdCore
import Logging
import NIOCore

extension HTTPChannelBuilder {
    /// HTTP1 channel builder supporting a websocket upgrade
    ///  - parameters
    public static func webSocketUpgrade<Handler: WebSocketDataHandler>(
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        configuration: WebSocketServerConfiguration = .init(),
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) async throws -> ShouldUpgradeResult<Handler>
    ) -> HTTPChannelBuilder<HTTP1AndWebSocketChannel<Handler>> {
        return .init { responder in
            return HTTP1AndWebSocketChannel(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder,
                configuration: configuration,
                shouldUpgrade: shouldUpgrade
            )
        }
    }

    /// HTTP1 channel builder supporting a websocket upgrade
    public static func webSocketUpgrade<Handler: WebSocketDataHandler>(
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        configuration: WebSocketServerConfiguration = .init(),
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) throws -> ShouldUpgradeResult<Handler>
    ) -> HTTPChannelBuilder<HTTP1AndWebSocketChannel<Handler>> {
        return .init { responder in
            return HTTP1AndWebSocketChannel<Handler>(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder,
                configuration: configuration,
                shouldUpgrade: shouldUpgrade
            )
        }
    }
}
