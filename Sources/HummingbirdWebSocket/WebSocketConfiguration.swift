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

public enum WebSocketType: Sendable {
    case client
    case server
}

/// Configuration for a WebSocket server
public protocol WebSocketConfiguration: Sendable {
    /// Max WebSocket frame size that can be sent/received
    var maxFrameSize: Int { get }

    // WebSocket type
    var type: WebSocketType { get }
}
