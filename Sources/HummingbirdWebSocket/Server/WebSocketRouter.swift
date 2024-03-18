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

public struct WebSocketRouterContext: Sendable {
    public init() {
        self.handler = .init(nil)
    }

    let handler: NIOLockedValueBox<WebSocketDataCallbackHandler?>
}

public protocol WebSocketRequestContext: RequestContext, WebSocketContextProtocol {
    var webSocket: WebSocketRouterContext { get }
}

public struct BasicWebSocketRequestContext: WebSocketRequestContext {
    public var coreContext: CoreRequestContext
    public let webSocket: WebSocketRouterContext

    public init(channel: Channel, logger: Logger) {
        self.coreContext = .init(allocator: channel.allocator, logger: logger)
        self.webSocket = .init()
    }
}

public enum RouterShouldUpgrade: Sendable {
    case dontUpgrade
    case upgrade(HTTPFields)
}

extension RouterMethods {
    /// GET path for async closure returning type conforming to ResponseGenerator
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

extension HTTP1AndWebSocketChannel {
    ///  Initialize HTTP1AndWebSocketChannel with async `shouldUpgrade` function
    /// - Parameters:
    ///   - additionalChannelHandlers: Additional channel handlers to add
    ///   - responder: HTTP responder
    ///   - maxFrameSize: Max frame size WebSocket will allow
    ///   - webSocketRouter: WebSocket router
    /// - Returns: Upgrade result future
    public init<Context: WebSocketRequestContext, ResponderBuilder: HTTPResponderBuilder>(
        additionalChannelHandlers: @escaping @Sendable () -> [any RemovableChannelHandler] = { [] },
        responder: @escaping @Sendable (Request, Channel) async throws -> Response = { _, _ in throw HTTPError(.notImplemented) },
        maxFrameSize: Int = (1 << 14),
        webSocketRouter: ResponderBuilder
    ) where Handler == WebSocketDataCallbackHandler, ResponderBuilder.Responder.Context == Context {
        let webSocketRouterResponder = webSocketRouter.buildResponder()
        self.init(additionalChannelHandlers: additionalChannelHandlers, responder: responder, maxFrameSize: maxFrameSize) { head, channel, logger in
            let request = Request(head: head, body: .init(buffer: .init()))
            let context = Context(channel: channel, logger: logger.with(metadataKey: "hb_id", value: .stringConvertible(RequestID())))
            do {
                let response = try await webSocketRouterResponder.respond(to: request, context: context)
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
    ///  - parameters
    public static func webSocketUpgrade<ResponderBuilder: HTTPResponderBuilder>(
        additionalChannelHandlers: @autoclosure @escaping @Sendable () -> [any RemovableChannelHandler] = [],
        maxFrameSize: Int = 1 << 14,
        webSocketRouter: ResponderBuilder
    ) -> HTTPChannelBuilder<HTTP1AndWebSocketChannel<WebSocketDataCallbackHandler>> where ResponderBuilder.Responder.Context: WebSocketRequestContext {
        return .init { responder in
            return HTTP1AndWebSocketChannel(
                additionalChannelHandlers: additionalChannelHandlers,
                responder: responder,
                maxFrameSize: maxFrameSize,
                webSocketRouter: webSocketRouter
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

/// Generate Unique ID for each request
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
