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

import WSCore

/// Configuration for a WebSocket server
public struct WebSocketServerConfiguration: Sendable {
    /// Max websocket frame size that can be sent/received
    public var maxFrameSize: Int
    /// WebSocket extensions
    public var extensions: [any WebSocketExtensionBuilder]
    /// Auto ping
    public var autoPing: AutoPingSetup
    /// How long server should wait for close frame from client before timing out
    public var closeTimeout: Duration
    /// Should we check text messages are valid UTF8
    public var validateUTF8: Bool

    /// Initialize WebSocketClient configuration
    ///   - Paramters
    ///     - maxFrameSize: Max websocket frame size that can be sent/received
    ///     - additionalHeaders: Additional headers to be sent with the initial HTTP request
    ///     - autoPing: Whether we should enable an automatic ping at a fixed period
    ///     - validateUTF8: Should we check text messages are valid UTF8
    public init(
        maxFrameSize: Int = (1 << 14),
        extensions: [WebSocketExtensionFactory] = [],
        autoPing: AutoPingSetup = .enabled(timePeriod: .seconds(30)),
        closeTimeout: Duration = .seconds(15),
        validateUTF8: Bool = false
    ) {
        self.maxFrameSize = maxFrameSize
        self.extensions = extensions.map { $0.build() }
        self.autoPing = autoPing
        self.closeTimeout = closeTimeout
        self.validateUTF8 = validateUTF8
    }
}
