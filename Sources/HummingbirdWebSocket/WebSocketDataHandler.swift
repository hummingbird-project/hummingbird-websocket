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
import HTTPTypes
import Logging
import NIOCore
import NIOWebSocket

/// Protocol for web socket data handling
///
/// This is the users interface into HummingbirdWebSocket. They provide an implementation of this protocol when
/// contructing their WebSocket upgrade handler. The user needs to return a type conforming to this protocol in
/// the `shouldUpgrade` closure in HTTP1AndWebSocketChannel.init
public struct WebSocketDataHandler<Context: WebSocketContextProtocol>: Sendable {
    /// Handler closure type
    public typealias Handler = @Sendable (WebSocketHandlerInbound, WebSocketHandlerOutboundWriter, Context) async throws -> Void
    /// Context sent to handler
    let context: Context
    /// handler function
    let handler: Handler

    public init(context: Context, handler: @escaping Handler) {
        self.context = context
        self.handler = handler
    }

    func withContext(channel: Channel, logger: Logger) -> Self {
        .init(context: .init(channel: channel, logger: logger), handler: self.handler)
    }
}
