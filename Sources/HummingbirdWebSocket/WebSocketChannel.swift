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
@_spi(WSInternal) import WSCore

/// Child channel supporting a web socket upgrade from HTTP1
public struct HTTP1WebSocketUpgradeChannel: ServerChildChannel, HTTPChannelHandler {
    public typealias WebSocketChannelHandler = @Sendable (NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Logger) async -> Void
    /// Upgrade result (either a websocket AsyncChannel, or an HTTP1 AsyncChannel)
    public enum UpgradeResult: Sendable {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, WebSocketChannelHandler, Logger)
        case notUpgraded(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
        case failedUpgrade(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Logger)
    }

    public struct Value: ServerChildChannelValue {
        let upgradeResult: EventLoopFuture<UpgradeResult>
        public let channel: Channel
    }

    /// Basic context implementation of ``/WSCore/WebSocketContext``.
    /// Used by non-router web socket handle function
    public struct Context: WebSocketContext {
        public let logger: Logger

        internal init(logger: Logger) {
            self.logger = logger
        }
    }

    ///  Initialize HTTP1AndWebSocketChannel with synchronous `shouldUpgrade` function
    /// - Parameters:
    ///   - responder: HTTP responder
    ///   - configuration: WebSocket configuration
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - shouldUpgrade: Function returning whether upgrade should be allowed
    public init(
        responder: @escaping HTTPChannelHandler.Responder,
        configuration: WebSocketServerConfiguration,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) throws -> ShouldUpgradeResult<WebSocketDataHandler<Context>>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.configuration = configuration
        self.shouldUpgrade = { head, channel, logger -> EventLoopFuture<ShouldUpgradeResult<WebSocketChannelHandler>> in
            channel.eventLoop.makeCompletedFuture { () -> ShouldUpgradeResult<WebSocketChannelHandler> in
                try shouldUpgrade(head, channel, logger)
                    .map { headers, handler -> (HTTPFields, WebSocketChannelHandler) in
                        let (headers, extensions) = try Self.webSocketExtensionNegotiation(
                            extensionBuilders: configuration.extensions,
                            requestHeaders: head.headerFields,
                            responseHeaders: headers,
                            logger: logger
                        )
                        return (
                            headers,
                            { asyncChannel, logger in
                                let context = Context(logger: logger)
                                do {
                                    _ = try await WebSocketHandler.handle(
                                        type: .server,
                                        configuration: .init(
                                            extensions: extensions,
                                            autoPing: configuration.autoPing,
                                            closeTimeout: configuration.closeTimeout,
                                            validateUTF8: configuration.validateUTF8
                                        ),
                                        asyncChannel: asyncChannel,
                                        context: context,
                                        handler: handler
                                    )
                                } catch {
                                    logger.debug("WebSocket handler error", metadata: ["error.type": "\(error)"])
                                }
                            }
                        )
                    }
            }
        }
        self.responder = responder
    }

    @available(*, deprecated, renamed: "init(responder:configuration:additionalChannelHandlers:shouldUpgrade:)")
    @_documentation(visibility: internal)
    public init(
        responder: @escaping HTTPChannelHandler.Responder,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        configuration: WebSocketServerConfiguration,
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) async throws -> ShouldUpgradeResult<WebSocketDataHandler<Context>>
    ) {
        self.init(
            responder: responder,
            configuration: configuration,
            additionalChannelHandlers: additionalChannelHandlers,
            shouldUpgrade: shouldUpgrade
        )
    }

    ///  Initialize HTTP1AndWebSocketChannel with async `shouldUpgrade` function
    /// - Parameters:
    ///   - responder: HTTP responder
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - configuration: WebSocket configuration
    ///   - shouldUpgrade: Function returning whether upgrade should be allowed
    public init(
        responder: @escaping HTTPChannelHandler.Responder,
        configuration: WebSocketServerConfiguration,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        shouldUpgrade: @escaping @Sendable (HTTPRequest, Channel, Logger) async throws -> ShouldUpgradeResult<WebSocketDataHandler<Context>>
    ) {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.configuration = configuration
        self.shouldUpgrade = { head, channel, logger -> EventLoopFuture<ShouldUpgradeResult<WebSocketChannelHandler>> in
            let promise = channel.eventLoop.makePromise(of: ShouldUpgradeResult<WebSocketChannelHandler>.self)
            promise.completeWithTask {
                try await shouldUpgrade(head, channel, logger)
                    .map { headers, handler in
                        let (headers, extensions) = try Self.webSocketExtensionNegotiation(
                            extensionBuilders: configuration.extensions,
                            requestHeaders: head.headerFields,
                            responseHeaders: headers,
                            logger: logger
                        )
                        return (
                            headers,
                            { asyncChannel, logger in
                                let context = Context(logger: logger)
                                do {
                                    _ = try await WebSocketHandler.handle(
                                        type: .server,
                                        configuration: .init(
                                            extensions: extensions,
                                            autoPing: configuration.autoPing,
                                            validateUTF8: configuration.validateUTF8
                                        ),
                                        asyncChannel: asyncChannel,
                                        context: context,
                                        handler: handler
                                    )
                                } catch {
                                    logger.debug("WebSocket handler error", metadata: ["error.type": "\(error)"])
                                }
                            }
                        )
                    }
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
        channel.eventLoop.makeCompletedFuture {
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
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(isOutboundHalfClosureEnabled: true)
                        )
                        return UpgradeResult.websocket(asyncChannel, handler, logger)
                    }
                }
            )

            let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    let childChannelHandlers: [any ChannelHandler] =
                        [HTTP1ToHTTPServerCodec(secure: false)] + self.additionalChannelHandlers() + [HTTPUserEventHandler(logger: logger)]
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(childChannelHandlers)
                        let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(isOutboundHalfClosureEnabled: true)
                        )
                        if upgradeAttempted.value {
                            return UpgradeResult.failedUpgrade(asyncChannel, logger)
                        } else {
                            return UpgradeResult.notUpgraded(asyncChannel)
                        }
                    }
                }
            )
            var upgradeConfiguration = NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult>(upgradeConfiguration: serverUpgradeConfiguration)
            upgradeConfiguration.enablePipelining = false  // HTTP is pipelined by NIOAsyncChannel
            upgradeConfiguration.enableErrorHandling = false  // These are handled by Hummingbird
            upgradeConfiguration.enableResponseHeaderValidation = false  // Swift HTTP Types are already doing this validation
            let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                configuration: upgradeConfiguration
            )

            return .init(upgradeResult: negotiationResultFuture, channel: channel)
        }
    }

    ///  Handle upgrade result output from channel
    /// - Parameters:
    ///   - upgradeResult: The upgrade result output by Channel
    ///   - logger: Logger to use
    public func handle(value: Value, logger: Logger) async {
        do {
            let result = try await value.upgradeResult.get()
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
        } catch let error as ChannelError where error == .inputClosed {
            logger.trace("Upgrade failed as input was closed")
        } catch {
            logger.error("Error handling upgrade result", metadata: ["error.type": .string("\(error)")])
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

    /// WebSocket extension negotiation
    /// - Parameters:
    ///   - requestHeaders: Request headers
    ///   - headers: Response headers
    ///   - logger: Logger
    /// - Returns: Response headers and extensions enabled
    static func webSocketExtensionNegotiation(
        extensionBuilders: [any WebSocketExtensionBuilder],
        requestHeaders: HTTPFields,
        responseHeaders: HTTPFields,
        logger: Logger
    ) throws -> (responseHeaders: HTTPFields, extensions: [any WebSocketExtension]) {
        var responseHeaders = responseHeaders
        let clientHeaders = WebSocketExtensionHTTPParameters.parseHeaders(requestHeaders)
        if clientHeaders.count > 0 {
            logger.trace(
                "Extensions requested",
                metadata: ["hb.ws.extensions": .string(clientHeaders.map(\.name).joined(separator: ","))]
            )
        }
        let extensionResponseHeaders = extensionBuilders.compactMap { $0.serverResponseHeader(to: clientHeaders) }
        responseHeaders.append(contentsOf: extensionResponseHeaders.map { .init(name: .secWebSocketExtensions, value: $0) })
        let extensions = try extensionBuilders.compactMap {
            try $0.serverExtension(from: clientHeaders)
        }
        if extensions.count > 0 {
            logger.debug(
                "Enabled extensions",
                metadata: ["hb.ws.extensions": .string(extensions.map(\.name).joined(separator: ","))]
            )
        }
        return (responseHeaders, extensions)
    }

    public let responder: HTTPChannelHandler.Responder
    let shouldUpgrade: @Sendable (HTTPRequest, Channel, Logger) -> EventLoopFuture<ShouldUpgradeResult<WebSocketChannelHandler>>
    let configuration: WebSocketServerConfiguration
    let additionalChannelHandlers: @Sendable () -> [any RemovableChannelHandler]
}
