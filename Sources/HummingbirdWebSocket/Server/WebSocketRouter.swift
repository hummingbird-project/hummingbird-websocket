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
public struct WebSocketRouterContext: Sendable {
    public init() {
        self.handler = .init(nil)
    }

    let handler: NIOLockedValueBox<WebSocketDataCallbackHandler?>
}

/// Request context protocol requirement for routers that support websockets
public protocol WebSocketRequestContext: RequestContext, WebSocketContextProtocol {
    var webSocket: WebSocketRouterContext { get }
}

/// Default implementation of a request context that supports WebSockets
public struct BasicWebSocketRequestContext: WebSocketRequestContext {
    public var coreContext: CoreRequestContext
    public let webSocket: WebSocketRouterContext

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
    ///   - handle: WebSocket channel handler
    @discardableResult public func ws(
        _ path: String = "",
        shouldUpgrade: @Sendable @escaping (Request, Context) async throws -> RouterShouldUpgrade = { _, _ in .upgrade([:]) },
        handle: @escaping WebSocketDataCallbackHandler.Callback
    ) -> Self where Context: WebSocketRequestContext {
        return on(path, method: .get) { request, context -> Response in
            let result = try await shouldUpgrade(request, context)
            switch result {
            case .dontUpgrade:
                return .init(status: .methodNotAllowed)
            case .upgrade(let headers):
                context.webSocket.handler.withLockedValue { $0 = WebSocketDataCallbackHandler(handle) }
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
    let handle: WebSocketDataCallbackHandler.Callback

    /// Initialize WebSocketUpgradeMiddleare
    /// - Parameters:
    ///   - shouldUpgrade: Return whether the WebSocket upgrade should occur
    ///   - handle: WebSocket handler
    public init(
        shouldUpgrade: @Sendable @escaping (Request, Context) async throws -> RouterShouldUpgrade = { _, _ in .upgrade([:]) },
        handle: @escaping WebSocketDataCallbackHandler.Callback
    ) {
        self.shouldUpgrade = shouldUpgrade
        self.handle = handle
    }

    /// WebSocketUpgradeMiddleware handler
    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let result = try await shouldUpgrade(request, context)
        switch result {
        case .dontUpgrade:
            return .init(status: .methodNotAllowed)
        case .upgrade(let headers):
            context.webSocket.handler.withLockedValue { $0 = WebSocketDataCallbackHandler(self.handle) }
            return .init(status: .ok, headers: headers)
        }
    }
}

extension HTTP1AndWebSocketChannel {
    ///  Initialize HTTP1AndWebSocketChannel with async `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - webSocketRouter: WebSocket router
    /// - Returns: Upgrade result future
    public init<Context: WebSocketRequestContext, WSResponder: HTTPResponder>(
        responder: @escaping @Sendable (Request, Channel) async throws -> Response,
        webSocketResponder: WSResponder,
        configuration: WebSocketServerConfiguration,
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] }
    ) where Handler == WebSocketDataCallbackHandler, WSResponder.Context == Context {
        self.init(responder: responder, configuration: configuration, additionalChannelHandlers: additionalChannelHandlers) { head, channel, logger in
            let request = Request(head: head, body: .init(buffer: .init()))
            let context = Context(channel: channel, logger: logger.with(metadataKey: "hb_id", value: .stringConvertible(RequestID())))
            do {
                let response = try await webSocketResponder.respond(to: request, context: context)
                if response.status == .ok, let webSocketHandler = context.webSocket.handler.withLockedValue({ $0 }) {
                    return .upgrade(response.headers, webSocketHandler)
                } else {
                    return .dontUpgrade
                }
            } catch {
                return .dontUpgrade
            }
        }
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
    ) -> HTTPChannelBuilder<HTTP1AndWebSocketChannel<WebSocketDataCallbackHandler>> where WSResponderBuilder.Responder.Context: WebSocketRequestContext {
        let webSocketReponder = webSocketRouter.buildResponder()
        return .init { responder in
            return HTTP1AndWebSocketChannel(
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

/// Generate Unique ID for each request. This is a duplicate of the RequestID in Hummingbird
package struct RequestID: CustomStringConvertible {
    let low: UInt64

    package init() {
        self.low = Self.globalRequestID.loadThenWrappingIncrement(by: 1, ordering: .relaxed)
    }

    package var description: String {
        Self.high + self.formatAsHexWithLeadingZeros(self.low)
    }

    func formatAsHexWithLeadingZeros(_ value: UInt64) -> String {
        let string = String(value, radix: 16)
        if string.count < 16 {
            return String(repeating: "0", count: 16 - string.count) + string
        } else {
            return string
        }
    }

    private static let high = String(UInt64.random(in: .min ... .max), radix: 16)
    private static let globalRequestID = ManagedAtomic<UInt64>(UInt64.random(in: .min ... .max))
}
