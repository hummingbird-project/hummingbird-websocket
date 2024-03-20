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

/// Handle websocket data and text blocks
public typealias WebSocketDataHandler<Context: WebSocketContextProtocol> = @Sendable (WebSocketHandlerInbound, WebSocketHandlerOutboundWriter, Context) async throws -> Void

/// Struct holding for web socket data handler and context.
public struct WebSocketDataHandlerAndContext<Context: WebSocketContextProtocol>: Sendable {
    /// Context sent to handler
    let context: Context
    /// handler function
    let handler: WebSocketDataHandler<Context>

    public init(context: Context, handler: @escaping WebSocketDataHandler<Context>) {
        self.context = context
        self.handler = handler
    }

    func withContext(channel: Channel, logger: Logger) -> Self {
        .init(context: .init(channel: channel, logger: logger), handler: self.handler)
    }
}
