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

import NIOCore
import NIOWebSocket

/// WebSocket
public struct WebSocket: Sendable {
    enum SocketType: Sendable {
        case client
        case server
    }

    /// Inbound stream type
    public typealias Inbound = WebSocketInboundStream
    /// Outbound writer type
    public typealias Outbound = WebSocketOutboundWriter

    /// Inbound stream
    public let inbound: Inbound
    /// Outbound writer
    public let outbound: Outbound

    init(type: SocketType, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>, allocator: ByteBufferAllocator) {
        self.inbound = .init()
        self.outbound = .init(type: type, allocator: allocator, outbound: outbound)
    }
}
