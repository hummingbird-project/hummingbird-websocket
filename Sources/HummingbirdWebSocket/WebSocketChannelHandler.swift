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
        responder: @escaping @Sendable (HBRequest, Channel) async throws -> HBResponse = { _, _ in throw HBHTTPError(.notImplemented) }
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.responder = responder
    }

    public func setup(channel: Channel, configuration: HBServerConfiguration, logger: Logger) -> EventLoopFuture<Value> {
        return channel.eventLoop.makeCompletedFuture {
            let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                shouldUpgrade: { channel, _ in
                    channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                },
                upgradePipelineHandler: { channel, _ in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        let handler: WebSocketHandler = { inbound, outbound in
                            for try await data in inbound {
                                try await outbound.write(data)
                            }
                        }
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
    let additionalChannelHandlers: @Sendable () -> [any RemovableChannelHandler]
}
