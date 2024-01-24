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
public protocol HBWebSocketDataHandler: Sendable {
    /// Context type supplied to the handle function.
    /// 
    /// The `HBWebSocketDataHandler` can chose to setup a context or accept the default one from
    /// ``HBWebSocketHandler``.
    associatedtype Context: HBWebSocketContextProtocol = HBWebSocketContext
    /// If a `HBWebSocketDataHandler` requires a context with custom data it should
    /// setup this variable on initialization
    var alreadySetupContext: Context? { get }
    ///  Handler WebSocket data packets
    /// - Parameters:
    ///   - inbound: An AsyncSequence of text or binary WebSocket frames.
    ///   - outbound: An outbound Writer to write websocket frames to
    ///   - context: Associated context to this websocket channel
    func handle(_ inbound: HBWebSocketHandlerInbound, _ outbound: HBWebSocketHandlerOutboundWriter, context: Context) async throws
}

extension HBWebSocketDataHandler {
    /// Default implementaion of ``alreadySetupContext`` returns nil, so the Context will be
    /// created by the ``HBWebSocketChannelHandler``
    public var alreadySetupContext: Context? { nil }
}

/// HBWebSocketDataHandler that is is initialized via a callback
public struct HBWebSocketDataCallbackHandler: HBWebSocketDataHandler {
    public typealias Callback = @Sendable (HBWebSocketHandlerInbound, HBWebSocketHandlerOutboundWriter, HBWebSocketContext) async throws -> Void

    let callback: Callback

    public init(_ callback: @escaping Callback) {
        self.callback = callback
    }

    ///  Handler WebSocket data packets by passing directly to the callback
    public func handle(_ inbound: HBWebSocketHandlerInbound, _ outbound: HBWebSocketHandlerOutboundWriter, context: HBWebSocketContext) async throws {
        try await self.callback(inbound, outbound, context)
    }
}

extension ShouldUpgradeResult where Value == HBWebSocketDataCallbackHandler {
    /// Extension to ShouldUpgradeResult that takes just a callback
    public static func upgrade(_ headers: HTTPHeaders, _ callback: @escaping HBWebSocketDataCallbackHandler.Callback) -> Self {
        .upgrade(headers, HBWebSocketDataCallbackHandler(callback))
    }
}
