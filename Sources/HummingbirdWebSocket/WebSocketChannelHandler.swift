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

/// Child channel supporting a web socket upgrade
public struct HTTP1AndWebSocketChannel<Handler: HBWebSocketDataHandler>: HBChildChannel, HTTPChannelHandler {
    public enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Handler)
        case notUpgraded(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
    }

    public typealias Value = EventLoopFuture<UpgradeResult>

    public init(
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        responder: @escaping @Sendable (HBRequest, Channel) async throws -> HBResponse = { _, _ in throw HBHTTPError(.notImplemented) },
        maxFrameSize: Int = (1 << 14),
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<ShouldUpgradeResult<Handler>>
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