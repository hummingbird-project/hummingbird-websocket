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

import HTTPTypes
import HummingbirdCore
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOWebSocket

/// Child channel supporting a web socket upgrade from HTTP1
public struct HTTP1AndWebSocketChannel<Handler: HBWebSocketDataHandler>: HBChildChannel, HTTPChannelHandler {
    /// Upgrade result (either a websocket AsyncChannel, or an HTTP1 AsyncChannel)
    public enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Handler)
        case notUpgraded(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
    }

    public typealias Value = EventLoopFuture<UpgradeResult>

    ///  Initialize HTTP1AndWebSocketChannel with async `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - shouldUpgrade: Function returning whether upgrade should be allowed
    /// - Returns: Upgrade result future
    public init(
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        responder: @escaping @Sendable (HBRequest, Channel) async throws -> HBResponse = { _, _ in throw HBHTTPError(.notImplemented) },
        maxFrameSize: Int = (1 << 14),
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) throws -> ShouldUpgradeResult<Handler>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.maxFrameSize = maxFrameSize
        self.shouldUpgrade = { channel, head in
            channel.eventLoop.makeCompletedFuture {
                try shouldUpgrade(channel, head)
            }
        }
        self.responder = responder
    }

    ///  Initialize HTTP1AndWebSocketChannel with synchronous `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - shouldUpgrade: Function returning whether upgrade should be allowed
    /// - Returns: Upgrade result future
    public init(
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        responder: @escaping @Sendable (HBRequest, Channel) async throws -> HBResponse = { _, _ in throw HBHTTPError(.notImplemented) },
        maxFrameSize: Int = (1 << 14),
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) async throws -> ShouldUpgradeResult<Handler>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.maxFrameSize = maxFrameSize
        self.shouldUpgrade = { channel, head in
            let promise = channel.eventLoop.makePromise(of: ShouldUpgradeResult<Handler>.self)
            promise.completeWithTask {
                try await shouldUpgrade(channel, head)
            }
            return promise.futureResult
        }
        self.responder = responder
    }

    ///  Setup channel to accept HTTP1 with a WebSocket upgrade
    /// - Parameters:
    ///   - channel: Child channel
    ///   - configuration: Server configuration
    ///   - logger: Logger used by upgrade
    /// - Returns: Negotiated result future
    public func setup(channel: Channel, logger: Logger) -> EventLoopFuture<Value> {
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

    ///  Handle upgrade result output from channel
    /// - Parameters:
    ///   - upgradeResult: The upgrade result output by Channel
    ///   - logger: Logger to use
    public func handle(value upgradeResult: EventLoopFuture<UpgradeResult>, logger: Logger) async {
        do {
            let result = try await upgradeResult.get()
            switch result {
            case .notUpgraded(let http1):
                await handleHTTP(asyncChannel: http1, logger: logger)
            case .websocket(let asyncChannel, let handler):
                let webSocket = HBWebSocketHandler(asyncChannel: asyncChannel, type: .server)
                let context = handler.alreadySetupContext ?? .init(logger: logger, allocator: asyncChannel.channel.allocator)
                await webSocket.handle(handler: handler, context: context)
            }
        } catch {
            logger.error("Error handling upgrade result: \(error)")
        }
    }

    public var responder: @Sendable (HBRequest, Channel) async throws -> HBResponse
    let shouldUpgrade: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<ShouldUpgradeResult<Handler>>
    let maxFrameSize: Int
    let additionalChannelHandlers: @Sendable () -> [any RemovableChannelHandler]
}
