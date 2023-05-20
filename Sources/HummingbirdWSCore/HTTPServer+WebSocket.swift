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
        extensions extensionConfigs: [WebSocketExtensionConfig] = [],
        shouldUpgrade: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> = { channel, _ in return channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        onUpgrade: @escaping (HBWebSocket, HTTPRequestHead) -> Void
    ) {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: maxFrameSize,
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> in
                shouldUpgrade(channel, head).map { headers -> HTTPHeaders? in
                    var headers = headers ?? [:]
                    let clientHeaders = WebSocketExtensionHTTPParameters.parseHeaders(head.headers)
                    let responseHeaders = extensionConfigs.compactMap { $0.serverResponseHeader(to: clientHeaders) }
                    headers.add(contentsOf: responseHeaders.map { (name: "Sec-WebSocket-Extensions", value: $0) })
                    return headers
                }
            },
            upgradePipelineHandler: { (channel: Channel, head: HTTPRequestHead) -> EventLoopFuture<Void> in
                let clientHeaders = WebSocketExtensionHTTPParameters.parseHeaders(head.headers)
                do {
                    let extensions = try extensionConfigs.compactMap { try $0.serverExtension(from: clientHeaders) }
                    let webSocket = HBWebSocket(channel: channel, type: .server, extensions: extensions)
                    return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket)).map { _ in
                        onUpgrade(webSocket, head)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        )
        self.httpChannelInitializer.addProtocolUpgrader(upgrader)
    }
}
