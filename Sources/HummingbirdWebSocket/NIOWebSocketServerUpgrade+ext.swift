//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPTypesHTTP1
import NIOWebSocket

/// Should HTTP channel upgrade to WebSocket
public enum ShouldUpgradeResult<Value: Sendable>: Sendable {
    case dontUpgrade
    case upgrade(HTTPFields = [:], Value)

    /// Map upgrade result to difference type
    func map<Result>(_ map: (HTTPFields, Value) throws -> (HTTPFields, Result)) rethrows -> ShouldUpgradeResult<Result> {
        switch self {
        case .dontUpgrade:
            return .dontUpgrade
        case .upgrade(let headers, let value):
            let result = try map(headers, value)
            return .upgrade(result.0, result.1)
        }
    }
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
    convenience init<Value>(
        maxFrameSize: Int = 1 << 14,
        enableAutomaticErrorHandling: Bool = true,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequest) -> EventLoopFuture<ShouldUpgradeResult<Value>>,
        upgradePipelineHandler: @escaping @Sendable (Channel, Value) -> EventLoopFuture<UpgradeResult>
    ) {
        let shouldUpgradeResult = NIOLockedValueBox<Value?>(nil)
        self.init(
            maxFrameSize: maxFrameSize,
            enableAutomaticErrorHandling: enableAutomaticErrorHandling,
            shouldUpgrade: { (channel, head: HTTPRequestHead) in
                let request: HTTPRequest
                do {
                    request = try HTTPRequest(head, secure: false, splitCookie: false)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return shouldUpgrade(channel, request).map { result in
                    switch result {
                    case .dontUpgrade:
                        return nil
                    case .upgrade(let headers, let value):
                        shouldUpgradeResult.withLockedValue { $0 = value }
                        return .init(headers)
                    }
                }
            },
            upgradePipelineHandler: { channel, _ in
                let result = shouldUpgradeResult.withLockedValue { $0 }
                if let result {
                    return upgradePipelineHandler(channel, result)
                } else {
                    preconditionFailure("Should not be running updatePipelineHander if shouldUpgrade failed")
                }
            }
        )
    }
}
