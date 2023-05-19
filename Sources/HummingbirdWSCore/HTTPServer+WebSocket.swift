//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HummingbirdCore
import NIOCore
import NIOHTTP1
import NIOWebSocket

extension HBHTTPServer {
    /// Add WebSocket upgrade option
    /// - Parameters:
    ///   - shouldUpgrade: Closure returning whether upgrade should happen
    ///   - onUpgrade: Closure called once upgrade has happened. Includes the `HBWebSocket` created to service the WebSocket connection.
    public func addWebSocketUpgrade(
        shouldUpgrade: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> = { channel, _ in return channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        onUpgrade: @escaping (HBWebSocket, HTTPRequestHead) -> Void
    ) {
        return self.addWebSocketUpgrade(maxFrameSize: 1 << 14, shouldUpgrade: shouldUpgrade, onUpgrade: onUpgrade)
    }

    /// Add WebSocket upgrade option
    /// - Parameters:
    ///   - maxFrameSize: Maximum size for a single frame
    ///   - shouldUpgrade: Closure returning whether upgrade should happen
    ///   - onUpgrade: Closure called once upgrade has happened. Includes the `HBWebSocket` created to service the WebSocket connection.
    public func addWebSocketUpgrade(
        maxFrameSize: Int,
        extensions: [WebSocketExtensionConfig] = [],
        shouldUpgrade: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> = { channel, _ in return channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        onUpgrade: @escaping (HBWebSocket, HTTPRequestHead) -> Void
    ) {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: maxFrameSize,
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> in
                shouldUpgrade(channel, head).map { headers -> HTTPHeaders? in
                    var headers = headers ?? [:]
                    let clientExtensions = WebSocketExtensionHTTPParameters.parseHeaders(head.headers, from: .client)
                    let responseExtensions = extensions.respond(to: clientExtensions)
                    headers.add(contentsOf: responseExtensions.map { (name: "Sec-WebSocket-Extensions", value: $0.serverResponseHeader()) })
                    return headers
                }
            },
            upgradePipelineHandler: { (channel: Channel, head: HTTPRequestHead) -> EventLoopFuture<Void> in
                let clientExtensions = WebSocketExtensionHTTPParameters.parseHeaders(head.headers, from: .client)
                let webSocket = HBWebSocket(channel: channel, type: .server, extensions: extensions.respond(to: clientExtensions))
                return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket)).map { _ in
                    onUpgrade(webSocket, head)
                }
            }
        )
        self.httpChannelInitializer.addProtocolUpgrader(upgrader)
    }
}
