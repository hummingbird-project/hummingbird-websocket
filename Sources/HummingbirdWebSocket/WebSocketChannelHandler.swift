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

import HTTPTypes
import HummingbirdCore
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOWebSocket

public struct HTTP1AndWebSocketChannel: HBChildChannel, HTTPChannelHandler {
    public enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, WebSocketHandler)
        case notUpgraded(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
    }

    public typealias Value = EventLoopFuture<UpgradeResult>

    public init(
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        responder: @escaping @Sendable (HBRequest, Channel) async throws -> HBResponse = { _, _ in throw HBHTTPError(.notImplemented) },
        maxFrameSize: Int = (1 << 14),
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<ShouldUpgradeResult<WebSocketHandler>>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.maxFrameSize = maxFrameSize
        self.shouldUpgrade = shouldUpgrade
        self.responder = responder
    }

    public func setup(channel: Channel, configuration: HBServerConfiguration, logger: Logger) -> EventLoopFuture<Value> {
        return channel.eventLoop.makeCompletedFuture {
            let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                maxFrameSize: self.maxFrameSize,
                shouldUpgrade: { channel, head in
                    self.shouldUpgrade(channel, head)
                },
                upgradePipelineHandler: { channel, handler in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        return UpgradeResult.websocket(asyncChannel, handler)
                    }
                }
            )

            let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    let childChannelHandlers: [any ChannelHandler] =
                        [HTTP1ToHTTPServerCodec(secure: false)] +
                        self.additionalChannelHandlers() +
                        [HBHTTPUserEventHandler(logger: logger)]
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(childChannelHandlers)
                        let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(wrappingChannelSynchronously: channel)
                        return UpgradeResult.notUpgraded(asyncChannel)
                    }
                }
            )

            let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                configuration: .init(upgradeConfiguration: serverUpgradeConfiguration)
            )

            return negotiationResultFuture
        }
    }

    public func handle(value upgradeResult: EventLoopFuture<UpgradeResult>, logger: Logging.Logger) async {
        do {
            let result = try await upgradeResult.get()
            switch result {
            case .notUpgraded(let http1):
                await handleHTTP(asyncChannel: http1, logger: logger)
            case .websocket(let asyncChannel, let handler):
                let webSocket = HBWebSocket(asyncChannel: asyncChannel, type: .server, logger: logger)
                await webSocket.handle(handler)
            }
        } catch {
            logger.error("Error handling upgrade result: \(error)")
        }
    }

    public var responder: @Sendable (HBRequest, Channel) async throws -> HBResponse
    let shouldUpgrade: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<ShouldUpgradeResult<WebSocketHandler>>
    let maxFrameSize: Int
    let additionalChannelHandlers: @Sendable () -> [any RemovableChannelHandler]
}

public enum ShouldUpgradeResult<Value> {
    case notUpgraded
    case upgraded(HTTPHeaders, Value)
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
                    case .notUpgraded:
                        return nil
                    case .upgraded(let headers, let value):
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