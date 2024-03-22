//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2024 the Hummingbird authors
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
import NIOHTTPTypesHTTP1
import NIOWebSocket

struct WebSocketClientChannel: ClientConnectionChannel {
    enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, [any WebSocketExtension])
        case notUpgraded
    }

    typealias Value = EventLoopFuture<UpgradeResult>

    let url: String
    let handler: WebSocketDataHandler<WebSocketContext>
    let configuration: WebSocketClientConfiguration

    init(handler: @escaping WebSocketDataHandler<WebSocketContext>, url: String, configuration: WebSocketClientConfiguration) {
        self.url = url
        self.handler = handler
        self.configuration = configuration
    }

    func setup(channel: any Channel, logger: Logger) -> NIOCore.EventLoopFuture<Value> {
        channel.eventLoop.makeCompletedFuture {
            let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                maxFrameSize: self.configuration.maxFrameSize,
                upgradePipelineHandler: { channel, head in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        // work out what extensions we should add
                        let headerFields = HTTPFields(head.headers, splitCookie: false)
                        let serverExtensions = WebSocketExtensionHTTPParameters.parseHeaders(headerFields)
                        let extensions = try configuration.extensions.compactMap {
                            try $0.clientExtension(from: serverExtensions, eventLoop: channel.eventLoop)
                        }
                        return UpgradeResult.websocket(asyncChannel, extensions)
                    }
                }
            )

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "0")
            let additionalHeaders = HTTPHeaders(self.configuration.additionalHeaders)
            headers.add(contentsOf: additionalHeaders)
            headers.add(contentsOf: self.configuration.extensions.map { (name: "Sec-WebSocket-Extensions", value: $0.clientRequestHeader()) })

            let requestHead = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: self.url,
                headers: headers
            )

            let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                upgradeRequestHead: requestHead,
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    channel.eventLoop.makeCompletedFuture {
                        return UpgradeResult.notUpgraded
                    }
                }
            )

            let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
            )

            return negotiationResultFuture
        }
    }

    func handle(value: Value, logger: Logger) async throws {
        switch try await value.get() {
        case .websocket(let webSocketChannel, let extensions):
            let webSocket = WebSocketHandler(asyncChannel: webSocketChannel, type: .client, extensions: extensions)
            await webSocket.handle(handler: self.handler, context: WebSocketContext(channel: webSocketChannel.channel, logger: logger))
        case .notUpgraded:
            // The upgrade to websocket did not succeed.
            logger.debug("Upgrade declined")
            throw WebSocketClientError.webSocketUpgradeFailed
        }
    }
}
