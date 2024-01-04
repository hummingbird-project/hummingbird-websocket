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

public protocol HBWebSocketContextProtocol: Sendable {
    var logger: Logger { get }
    var allocator: ByteBufferAllocator { get }
    init(logger: Logger, allocator: ByteBufferAllocator)
}

public struct HBWebSocketContext: HBWebSocketContextProtocol {
    public let logger: Logger
    public let allocator: ByteBufferAllocator

    public init(logger: Logger, allocator: ByteBufferAllocator) {
        self.logger = logger
        self.allocator = allocator
    }
}
