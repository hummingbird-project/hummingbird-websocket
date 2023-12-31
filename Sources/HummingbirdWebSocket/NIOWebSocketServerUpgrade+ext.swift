//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOWebSocket

public enum ShouldUpgradeResult<Value: Sendable>: Sendable {
    case dontUpgrade
    case upgrade(HTTPHeaders, Value)
}

extension NIOTypedWebSocketServerUpgrader {
    /// Create a new ``NIOTypedWebSocketServerUpgrader``.
    ///
    /// - Parameters:
    ///   - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even. Users may set this to any value up to `UInt32.max`.
    ///   - enableAutomaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///   - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. It also 
    ///         creates state that is passed onto the `upgradePipelineHandler`. Should return
    ///         an `EventLoopFuture` containing `.notUpgraded` if the upgrade should be refused.
    ///   - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    public convenience init<Value>(
        maxFrameSize: Int = 1 << 14,
        enableAutomaticErrorHandling: Bool = true,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<ShouldUpgradeResult<Value>>,
        upgradePipelineHandler: @escaping @Sendable (Channel, Value) -> EventLoopFuture<UpgradeResult>
    ) {
        let shouldUpgradeResult = NIOLockedValueBox<Value?>(nil)
        self.init(
            maxFrameSize: maxFrameSize, 
            enableAutomaticErrorHandling: enableAutomaticErrorHandling, 
            shouldUpgrade: { channel, head in
                shouldUpgrade(channel, head).map { result in
                    switch result {
                    case .dontUpgrade:
                        return nil
                    case .upgrade(let headers, let value):
                        shouldUpgradeResult.withLockedValue { $0 = value }
                        return headers 
                    }
                }
            }, 
            upgradePipelineHandler: { channel, head in
                let result = shouldUpgradeResult.withLockedValue{ $0 }
                if let result {
                    return upgradePipelineHandler(channel, result)
                } else {
                    preconditionFailure("Should not be running updatePipelineHander if shouldUpgrade failed")
                }
            }
        )
    }
}