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

import Atomics
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOConcurrencyHelpers
import NIOCore

/// WebSocket Router context type.
///
/// Includes reference to optional websocket handler
public struct WebSocketRouterContext<Context: WebSocketRequestContext>: Sendable {
    /// Holds WebSocket context and handler to call
    struct Value: Sendable {
        let context: Context
        let handler: WebSocketDataHandler<Context>
    }

    public init() {
        self.handler = .init(nil)
    }

    let handler: NIOLockedValueBox<Value?>
}

/// Request context protocol requirement for routers that support websockets
public protocol WebSocketRequestContext: RequestContext, WebSocketContextProtocol {
    var webSocket: WebSocketRouterContext<Self> { get }
}

/// Default implementation of a request context that supports WebSockets
public struct BasicWebSocketRequestContext: WebSocketRequestContext {
    public var coreContext: CoreRequestContext
    public let webSocket: WebSocketRouterContext<Self>

    public init(channel: Channel, logger: Logger) {
        self.coreContext = .init(allocator: channel.allocator, logger: logger)
        self.webSocket = .init()
    }
}

/// Enum indicating whether a router `shouldUpgrade` function expects a
/// WebSocket upgrade or not
public enum RouterShouldUpgrade: Sendable {
    case dontUpgrade
    case upgrade(HTTPFields)
}

extension RouterMethods {
    /// Add path to router that support WebSocket upgrade
    /// - Parameters:
    ///   - path: Path to match
    ///   - shouldUpgrade: Should request be upgraded
    ///   - handler: WebSocket channel handler
    @discardableResult public func ws(
        _ path: String = "",
        shouldUpgrade: @Sendable @escaping (Request, Context) async throws -> RouterShouldUpgrade = { _, _ in .upgrade([:]) },
        onUpgrade handler: @escaping WebSocketDataHandler<Context>
    ) -> Self where Context: WebSocketRequestContext {
        return on(path, method: .get) { request, context -> Response in
            let result = try await shouldUpgrade(request, context)
            switch result {
            case .dontUpgrade:
                return .init(status: .methodNotAllowed)
            case .upgrade(let headers):
                context.webSocket.handler.withLockedValue { $0 = WebSocketRouterContext.Value(context: context, handler: handler) }
                return .init(status: .ok, headers: headers)
            }
        }
    }
}

/// An alternative way to add a WebSocket upgrade to a router via Middleware
///
/// This is primarily designed to be used with ``HummingbirdRouter/RouterBuilder`` but can be used
/// with ``Hummingbird/Router`` if you add a route immediately after it.
public struct WebSocketUpgradeMiddleware<Context: WebSocketRequestContext>: RouterMiddleware {
    let shouldUpgrade: @Sendable (Request, Context) async throws -> RouterShouldUpgrade
    let handler: WebSocketDataHandler<Context>

    /// Initialize WebSocketUpgradeMiddleare
    /// - Parameters:
    ///   - shouldUpgrade: Return whether the WebSocket upgrade should occur
    ///   - handle: WebSocket handler
    public init(
        shouldUpgrade: @Sendable @escaping (Request, Context) async throws -> RouterShouldUpgrade = { _, _ in .upgrade([:]) },
        onUpgrade handler: @escaping WebSocketDataHandler<Context>
    ) {
        self.shouldUpgrade = shouldUpgrade
        self.handler = handler
    }

    /// WebSocketUpgradeMiddleware handler
    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let result = try await shouldUpgrade(request, context)
        switch result {
        case .dontUpgrade:
            return .init(status: .methodNotAllowed)
        case .upgrade(let headers):
            context.webSocket.handler.withLockedValue { $0 = .init(context: context, handler: self.handler) }
            return .init(status: .ok, headers: headers)
        }
    }
}

extension HTTP1WebSocketUpgradeChannel {
    ///  Initialize HTTP1WebSocketUpgradeChannel with async `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - webSocketRouter: WebSocket router
    /// - Returns: Upgrade result future
    public init<WSResponder: HTTPResponder>(
        responder: @escaping @Sendable (Request, Channel) async throws -> Response,
        webSocketResponder: WSResponder,
        configuration: WebSocketServerConfiguration,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] }
    ) where WSResponder.Context: WebSocketRequestContext {
        self.additionalChannelHandlers = additionalChannelHandlers
        self.configuration = configuration
        self.shouldUpgrade = { head, channel, logger in
            let promise = channel.eventLoop.makePromise(of: ShouldUpgradeResult<WebSocketChannelHandler>.self)
            promise.completeWithTask {
                let request = Request(head: head, body: .init(buffer: .init()))
                let context = WSResponder.Context(channel: channel, logger: logger)
                do {
                    let response = try await webSocketResponder.respond(to: request, context: context)
                    if response.status == .ok, let webSocketHandler = context.webSocket.handler.withLockedValue({ $0 }) {
                        let (headers, extensions) = try Self.webSocketExtensionNegotiation(
                            extensionBuilders: configuration.extensions,
                            requestHeaders: head.headerFields,
                            responseHeaders: response.headers,
                            logger: logger
                        )
                        return .upgrade(headers) { asyncChannel, _ in
                            await WebSocketHandler.handle(
                                type: .server,
                                extensions: extensions,
                                autoPing: configuration.autoPing,
                                asyncChannel: asyncChannel,
                                context: webSocketHandler.context,
                                handler: webSocketHandler.handler
                            )
                        }
                    } else {
                        return .dontUpgrade
                    }
                } catch {
                    return .dontUpgrade
                }
            }
            return promise.futureResult
        }
        self.responder = responder
    }
}

extension HTTPChannelBuilder {
    /// HTTP1 channel builder supporting a websocket upgrade
    ///
    /// With this function you provide a separate router from the one you have supplied
    /// to ``Hummingbird/Application``. You can provide the same router as is used for
    /// standard HTTP routing, but it is preferable that you supply a separate one to
    /// avoid attempting to match against paths which will never produce a WebSocket upgrade.
    /// - Parameters:
    ///   - webSocketRouter: Router used for testing whether a WebSocket upgrade should occur
    ///   - configuration: WebSocket server configuration
    ///   - additionalChannelHandlers: Additional channel handlers to add to channel pipeline
    /// - Returns:
    public static func webSocketUpgrade<WSResponderBuilder: HTTPResponderBuilder>(
        webSocketRouter: WSResponderBuilder,
        configuration: WebSocketServerConfiguration = .init(),
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = []
    ) -> HTTPChannelBuilder<HTTP1WebSocketUpgradeChannel> where WSResponderBuilder.Responder.Context: WebSocketRequestContext {
        let webSocketReponder = webSocketRouter.buildResponder()
        return .init { responder in
            return HTTP1WebSocketUpgradeChannel(
                responder: responder,
                webSocketResponder: webSocketReponder,
                configuration: configuration,
                additionalChannelHandlers: additionalChannelHandlers
            )
        }
    }
}

extension Logger {
    /// Create new Logger with additional metadata value
    /// - Parameters:
    ///   - metadataKey: Metadata key
    ///   - value: Metadata value
    /// - Returns: Logger
    func with(metadataKey: String, value: MetadataValue) -> Logger {
        var logger = self
        logger[metadataKey: metadataKey] = value
        return logger
    }
}
