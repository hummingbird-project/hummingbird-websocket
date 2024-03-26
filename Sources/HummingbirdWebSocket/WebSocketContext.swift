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

import Logging
import NIOCore

/// Protocol for Context passsed to ``WebSocketDataHandler``
public protocol WebSocketContextProtocol: Sendable {
    var logger: Logger { get }
    var allocator: ByteBufferAllocator { get }
    init(channel: Channel, logger: Logger)
}

/// Default implementation of ``WebSocketContextProtocol``
public struct WebSocketContext: WebSocketContextProtocol {
    public let logger: Logger
    public let allocator: ByteBufferAllocator

    public init(channel: Channel, logger: Logger) {
        self.logger = logger
        self.allocator = channel.allocator
    }

    init(allocator: ByteBufferAllocator, logger: Logger) {
        self.allocator = allocator
        self.logger = logger
    }
}
