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

/// Configuration for a WebSocket server
public struct WebSocketServerConfiguration: Sendable {
    /// Max websocket frame size that can be sent/received
    public var maxFrameSize: Int

    /// Initialize WebSocketClient configuration
    ///   - Paramters
    ///     - maxFrameSize: Max websocket frame size that can be sent/received
    ///     - additionalHeaders: Additional headers to be sent with the initial HTTP request
    public init(
        maxFrameSize: Int = (1 << 14)
    ) {
        self.maxFrameSize = maxFrameSize
    }
}
