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

import Hummingbird
import Logging
import NIOCore

/// Base context passed around when we only need the logger or allocator
public protocol BaseWebSocketContext: Sendable {
    var allocator: ByteBufferAllocator { get }
    var logger: Logger { get }
}

/// Base context passed around when we only need the logger or allocator
public struct BasicWebSocketContext: BaseWebSocketContext {
    public let allocator: ByteBufferAllocator
    public let logger: Logger
}

/// Context that created this WebSocket
///
/// Include the HTTP request and context that initiated the WebSocket connection
public struct WebSocketContext<Context: BaseWebSocketContext>: BaseWebSocketContext {
    /// HTTP request that initiated the WebSocket connection
    public let request: HTTPRequest
    /// Request context at the time of WebSocket connection was initiated
    public let requestContext: Context

    init(request: HTTPRequest, context: Context) {
        self.request = request
        self.requestContext = context
    }

    /// Logger attached to request context
    public var logger: Logger { self.requestContext.logger }
    /// ByteBuffer allocator attached to request context
    public var allocator: ByteBufferAllocator { self.requestContext.allocator }
}
