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

extension HBHTTPChannelBuilder {
    public static func httpAndWebSocket(
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = []
    ) -> HBHTTPChannelBuilder<HTTP1AndWebSocketChannel> {
        return .init { responder in
            return HTTP1AndWebSocketChannel(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder
            )
        }
    }
}
