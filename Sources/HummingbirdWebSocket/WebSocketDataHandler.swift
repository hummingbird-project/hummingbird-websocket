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

import AsyncAlgorithms
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// Protocol for web socket data handling
///
/// This is the users interface into HummingbirdWebSocket. They provide an implementation of this protocol when
/// contructing their WebSocket upgrade handler. The user needs to return a type conforming to this protocol in
/// the `shouldUpgrade` closure in HTTP1AndWebSocketChannel.init
public protocol WebSocketDataHandler: Sendable {
    /// Context type supplied to the handle function.
    ///
    /// The `WebSocketDataHandler` can chose to setup a context or accept the default one from
    /// ``WebSocketHandler``.
    associatedtype Context: WebSocketContextProtocol = WebSocketContext
    /// If a `WebSocketDataHandler` requires a context with custom data it should
    /// setup this variable on initialization
    var alreadySetupContext: Context? { get }
    ///  Handler WebSocket data packets
    /// - Parameters:
    ///   - inbound: An AsyncSequence of text or binary WebSocket frames.
    ///   - outbound: An outbound Writer to write websocket frames to
    ///   - context: Associated context to this websocket channel
    func handle(_ inbound: WebSocketHandlerInbound, _ outbound: WebSocketHandlerOutboundWriter, context: Context) async throws
}

extension WebSocketDataHandler {
    /// Default implementaion of ``alreadySetupContext`` returns nil, so the Context will be
    /// created by the ``WebSocketChannelHandler``
    public var alreadySetupContext: Context? { nil }
}

/// WebSocketDataHandler that is is initialized via a callback
public struct WebSocketDataCallbackHandler: WebSocketDataHandler {
    public typealias Callback = @Sendable (WebSocketHandlerInbound, WebSocketHandlerOutboundWriter, WebSocketContext) async throws -> Void

    let callback: Callback

    public init(_ callback: @escaping Callback) {
        self.callback = callback
    }

    ///  Handler WebSocket data packets by passing directly to the callback
    public func handle(_ inbound: WebSocketHandlerInbound, _ outbound: WebSocketHandlerOutboundWriter, context: WebSocketContext) async throws {
        try await self.callback(inbound, outbound, context)
    }
}

extension ShouldUpgradeResult where Value == WebSocketDataCallbackHandler {
    /// Extension to ShouldUpgradeResult that takes just a callback
    public static func upgrade(_ headers: HTTPHeaders, _ callback: @escaping WebSocketDataCallbackHandler.Callback) -> Self {
        .upgrade(headers, WebSocketDataCallbackHandler(callback))
    }
}
