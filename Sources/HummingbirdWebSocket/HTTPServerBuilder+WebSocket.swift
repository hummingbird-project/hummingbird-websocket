//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import WSCore

extension HTTPServerBuilder {
    /// HTTP1 channel builder supporting a websocket upgrade
    ///  - parameters
    public static func http1WebSocketUpgrade(
        configuration: WebSocketServerConfiguration = .init(),
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        shouldUpgrade:
            @escaping @Sendable (HTTPRequest, Channel, Logger) async throws -> ShouldUpgradeResult<
                WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>
            >
    ) -> HTTPServerBuilder {
        .init { responder in
            HTTP1WebSocketUpgradeChannel(
                responder: responder,
                configuration: configuration,
                additionalChannelHandlers: additionalChannelHandlers,
                shouldUpgrade: shouldUpgrade
            )
        }
    }

    /// HTTP1 channel builder supporting a websocket upgrade
    public static func http1WebSocketUpgrade(
        configuration: WebSocketServerConfiguration = .init(),
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        shouldUpgrade:
            @escaping @Sendable (HTTPRequest, Channel, Logger) throws -> ShouldUpgradeResult<
                WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>
            >
    ) -> HTTPServerBuilder {
        .init { responder in
            HTTP1WebSocketUpgradeChannel(
                responder: responder,
                configuration: configuration,
                additionalChannelHandlers: additionalChannelHandlers,
                shouldUpgrade: shouldUpgrade
            )
        }
    }
}
