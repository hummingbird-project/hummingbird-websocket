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
import Hummingbird
import HummingbirdCore
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOWebSocket

/// Child channel supporting a web socket upgrade from HTTP1
public struct HTTP1AndWebSocketChannel: ServerChildChannel, HTTPChannelHandler {
    public typealias WebSocketChannelHandler = @Sendable (NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Logger) async -> Void
    /// Upgrade result (either a websocket AsyncChannel, or an HTTP1 AsyncChannel)
    public enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, WebSocketChannelHandler, Logger)
        case notUpgraded(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
        case failedUpgrade(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Logger)
    }

    public typealias Value = EventLoopFuture<UpgradeResult>

    ///  Setup channel to accept HTTP1 with a WebSocket upgrade
    /// - Parameters:
    ///   - channel: Child channel
    ///   - configuration: Server configuration
    ///   - logger: Logger used by upgrade
    /// - Returns: Negotiated result future
    public func setup(channel: Channel, logger: Logger) -> EventLoopFuture<Value> {
        return channel.eventLoop.makeCompletedFuture {
            let upgradeAttempted = NIOLoopBoundBox(false, eventLoop: channel.eventLoop)
            let logger = logger.with(metadataKey: "hb_id", value: .stringConvertible(RequestID()))
            let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                maxFrameSize: self.configuration.maxFrameSize,
                shouldUpgrade: { channel, head in
                    upgradeAttempted.value = true
                    return self.shouldUpgrade(head, channel, logger)
                },
                upgradePipelineHandler: { channel, handler in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        return UpgradeResult.websocket(asyncChannel, handler, logger)
                    }
                }
            )

            let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    let childChannelHandlers: [any ChannelHandler] =
                        [HTTP1ToHTTPServerCodec(secure: false)] +
                        self.additionalChannelHandlers() +
                        [HTTPUserEventHandler(logger: logger)]
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(childChannelHandlers)
                        let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(wrappingChannelSynchronously: channel)
                        if upgradeAttempted.value {
                            return UpgradeResult.failedUpgrade(asyncChannel, logger)
                        } else {
                            return UpgradeResult.notUpgraded(asyncChannel)
                        }
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
                await self.handleHTTP(asyncChannel: http1, logger: logger)

            case .failedUpgrade(let http1, let logger):
                logger.debug("Websocket upgrade failed")
                await self.write405(asyncChannel: http1, logger: logger)

            case .websocket(let asyncChannel, let handler, let logger):
                logger.debug("Websocket upgrade")
                await handler(asyncChannel, logger)
            }
        } catch {
            logger.error("Error handling upgrade result: \(error)")
        }
    }

    /// Upgrade failed we should write a 405
    private func write405(asyncChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, logger: Logger) async {
        do {
            try await asyncChannel.executeThenClose { _, outbound in
                let headers: HTTPFields = [
                    .connection: "close",
                    .contentLength: "0",
                ]
                let head = HTTPResponse(
                    status: .methodNotAllowed,
                    headerFields: headers
                )

                try await outbound.write(
                    contentsOf: [
                        .head(head),
                        .end(nil),
                    ]
                )
            }
        } catch {
            // we got here because we failed to either read or write to the channel
            logger.trace("Failed to write to Channel. Error: \(error)")
        }
    }

    public var responder: @Sendable (Request, Channel) async throws -> Response
    let shouldUpgrade: @Sendable (HTTPRequest, Channel, Logger) -> EventLoopFuture<ShouldUpgradeResult<WebSocketChannelHandler>>
    let configuration: WebSocketServerConfiguration
    let additionalChannelHandlers: @Sendable () -> [any RemovableChannelHandler]
}

extension HTTP1AndWebSocketChannel {
    ///  Initialize HTTP1AndWebSocketChannel with synchronous `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - shouldUpgrade: Function returning whether upgrade should be allowed
    /// - Returns: Upgrade result future
    public init(
        responder: @escaping @Sendable (Request, Channel) async throws -> Response,
        configuration: WebSocketServerConfiguration,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) throws -> ShouldUpgradeResult<WebSocketDataHandler<WebSocketContext>>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.configuration = configuration
        self.shouldUpgrade = { head, channel, logger in
            channel.eventLoop.makeCompletedFuture { () -> ShouldUpgradeResult<WebSocketChannelHandler> in
                try shouldUpgrade(head, channel, logger)
                    .map { handler in
                        return { asyncChannel, logger in
                            let webSocket = WebSocketHandler(asyncChannel: asyncChannel, type: .server)
                            let context = WebSocketContext(channel: channel, logger: logger)
                            await webSocket.handle(handler: handler, context: context)
                        }
                    }
            }
        }
        self.responder = responder
    }

    ///  Initialize HTTP1AndWebSocketChannel with async `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - shouldUpgrade: Function returning whether upgrade should be allowed
    /// - Returns: Upgrade result future
    public init(
        responder: @escaping @Sendable (Request, Channel) async throws -> Response,
        configuration: WebSocketServerConfiguration,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) async throws -> ShouldUpgradeResult<WebSocketDataHandler<WebSocketContext>>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.configuration = configuration
        self.shouldUpgrade = { head, channel, logger in
            let promise = channel.eventLoop.makePromise(of: ShouldUpgradeResult<WebSocketChannelHandler>.self)
            promise.completeWithTask {
                try await shouldUpgrade(head, channel, logger)
                    .map { handler in
                        return { asyncChannel, logger in
                            let webSocket = WebSocketHandler(asyncChannel: asyncChannel, type: .server)
                            let context = WebSocketContext(channel: channel, logger: logger)
                            await webSocket.handle(handler: handler, context: context)
                        }
                    }
            }
            return promise.futureResult
        }
        self.responder = responder
    }
}
