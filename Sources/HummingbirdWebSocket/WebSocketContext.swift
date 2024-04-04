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

/// Context for WebSocket
public protocol WebSocketContext: Sendable {
    var allocator: ByteBufferAllocator { get }
    var logger: Logger { get }
}

/// Basic context implementation of ``WebSocketContext``.
///
/// Used by non-router and client WebSocket connections
public struct BasicWebSocketContext: WebSocketContext {
    public let allocator: ByteBufferAllocator
    public let logger: Logger
}
